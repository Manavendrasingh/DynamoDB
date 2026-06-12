import { randomUUID } from 'node:crypto';
import { Injectable, NotFoundException } from '@nestjs/common';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DeleteCommand,
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  ScanCommand,
  UpdateCommand,
} from '@aws-sdk/lib-dynamodb';
import { CreateUserDto } from './dto/create-user.dto';
import { UpdateUserDto } from './dto/update-user.dto';
import { User } from './user.entity';

@Injectable()
export class UsersService {
  private readonly tableName = process.env.USERS_TABLE_NAME ?? 'Users';
  private readonly dynamoDb = DynamoDBDocumentClient.from(
    new DynamoDBClient({
      region: process.env.AWS_REGION ?? 'us-east-1',
    }),
  );

  async create(createUserDto: CreateUserDto): Promise<User> {
    const now = new Date().toISOString();
    const user: User = {
      id: randomUUID(),
      ...createUserDto,
      createdAt: now,
      updatedAt: now,
    };

    await this.dynamoDb.send(
      new PutCommand({
        TableName: this.tableName,
        Item: user,
      }),
    );

    return user;
  }

  async findAll(): Promise<User[]> {
    const result = await this.dynamoDb.send(
      new ScanCommand({
        TableName: this.tableName,
      }),
    );

    return (result.Items ?? []) as User[];
  }

  async findOne(id: string): Promise<User> {
    const result = await this.dynamoDb.send(
      new GetCommand({
        TableName: this.tableName,
        Key: { id },
      }),
    );

    if (!result.Item) {
      throw new NotFoundException(`User with id "${id}" not found`);
    }

    return result.Item as User;
  }

  async update(id: string, updateUserDto: UpdateUserDto): Promise<User> {
    const updateEntries = Object.entries(updateUserDto).filter(
      ([, value]) => value !== undefined,
    );

    if (updateEntries.length === 0) {
      return this.findOne(id);
    }

    const expressionAttributeNames: Record<string, string> = {
      '#updatedAt': 'updatedAt',
    };
    const expressionAttributeValues: Record<string, unknown> = {
      ':updatedAt': new Date().toISOString(),
    };
    const setExpressions = ['#updatedAt = :updatedAt'];

    updateEntries.forEach(([key, value]) => {
      expressionAttributeNames[`#${key}`] = key;
      expressionAttributeValues[`:${key}`] = value;
      setExpressions.push(`#${key} = :${key}`);
    });

    try {
      const result = await this.dynamoDb.send(
        new UpdateCommand({
          TableName: this.tableName,
          Key: { id },
          UpdateExpression: `SET ${setExpressions.join(', ')}`,
          ConditionExpression: 'attribute_exists(id)',
          ExpressionAttributeNames: expressionAttributeNames,
          ExpressionAttributeValues: expressionAttributeValues,
          ReturnValues: 'ALL_NEW',
        }),
      );

      return result.Attributes as User;
    } catch (error) {
      if (this.isConditionalCheckFailed(error)) {
        throw new NotFoundException(`User with id "${id}" not found`);
      }

      throw error;
    }
  }

  async remove(id: string): Promise<void> {
    try {
      await this.dynamoDb.send(
        new DeleteCommand({
          TableName: this.tableName,
          Key: { id },
          ConditionExpression: 'attribute_exists(id)',
        }),
      );
    } catch (error) {
      if (this.isConditionalCheckFailed(error)) {
        throw new NotFoundException(`User with id "${id}" not found`);
      }

      throw error;
    }
  }

  private isConditionalCheckFailed(error: unknown): boolean {
    return (
      typeof error === 'object' &&
      error !== null &&
      'name' in error &&
      error.name === 'ConditionalCheckFailedException'
    );
  }
}
