import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Trend, Rate } from 'k6/metrics';

export const options = {
  stages: [
    { duration: '30s', target: Number(__ENV.VUS ?? 500) },
    { duration: '1m', target: Number(__ENV.VUS ?? 500) },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
    create_user_duration: ['p(95)<700'],
    read_user_duration: ['p(95)<500'],
    update_user_duration: ['p(95)<700'],
    delete_user_duration: ['p(95)<700'],
    user_flow_failed: ['rate<0.01'],
  },
};

const createUserDuration = new Trend('create_user_duration');
const readUserDuration = new Trend('read_user_duration');
const updateUserDuration = new Trend('update_user_duration');
const deleteUserDuration = new Trend('delete_user_duration');
const userFlowFailed = new Rate('user_flow_failed');

const BASE_URL = (__ENV.BASE_URL ?? 'http://dynamo-db-api-dev-412780750.ap-south-1.elb.amazonaws.com').replace(/\/$/, '');
const headers = { 'Content-Type': 'application/json' };

export default function () {
  const uniqueId = `${__VU}-${__ITER}-${Date.now()}`;
  let userId;
  let failed = false;

  group('users CRUD flow', () => {
    const createPayload = JSON.stringify({
      name: `Load Test User ${uniqueId}`,
      email: `load-test-${uniqueId}@example.com`,
      phone: '9999999999',
      address: 'Load Test City',
    });

    const createRes = http.post(`${BASE_URL}/users`, createPayload, {
      headers,
      tags: { name: 'POST /users' },
    });
    createUserDuration.add(createRes.timings.duration);

    const createOk = check(createRes, {
      'create returned 201 or 200': (res) => res.status === 201 || res.status === 200,
      'create returned user id': (res) => Boolean(res.json('id')),
    });

    if (!createOk) {
      userFlowFailed.add(1);
      return;
    }

    userId = createRes.json('id');

    const getRes = http.get(`${BASE_URL}/users/${userId}`, {
      tags: { name: 'GET /users/:id' },
    });
    readUserDuration.add(getRes.timings.duration);

    failed =
      !check(getRes, {
        'read returned 200': (res) => res.status === 200,
        'read returned same user': (res) => res.json('id') === userId,
      }) || failed;

    const listRes = http.get(`${BASE_URL}/users`, {
      tags: { name: 'GET /users' },
    });
    readUserDuration.add(listRes.timings.duration);

    failed =
      !check(listRes, {
        'list returned 200': (res) => res.status === 200,
        'list returned an array': (res) => Array.isArray(res.json()),
      }) || failed;

    const updateRes = http.patch(
      `${BASE_URL}/users/${userId}`,
      JSON.stringify({ phone: '8888888888' }),
      {
        headers,
        tags: { name: 'PATCH /users/:id' },
      },
    );
    updateUserDuration.add(updateRes.timings.duration);

    failed =
      !check(updateRes, {
        'update returned 200': (res) => res.status === 200,
        'update changed phone': (res) => res.json('phone') === '8888888888',
      }) || failed;

    const deleteRes = http.del(`${BASE_URL}/users/${userId}`, null, {
      tags: { name: 'DELETE /users/:id' },
    });
    deleteUserDuration.add(deleteRes.timings.duration);

    failed =
      !check(deleteRes, {
        'delete returned 204': (res) => res.status === 204,
      }) || failed;

    userFlowFailed.add(failed ? 1 : 0);
  });

  sleep(Number(__ENV.SLEEP_SECONDS ?? 1));
}
