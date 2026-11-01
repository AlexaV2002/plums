import {
  BadRequestException,
  ForbiddenException,
  NotFoundException,
} from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { DmGateway } from './dm.gateway';
import {
  DmService,
  toDmConversation,
  toDmMessage,
  toDmUser,
} from './dm.service';

describe('DmService', () => {
  let service: DmService;
  let prisma: {
    $transaction: jest.Mock;
    user: { findUnique: jest.Mock };
    directConversation: {
      create: jest.Mock;
      findUnique: jest.Mock;
      findMany: jest.Mock;
      update: jest.Mock;
    };
    directMessage: {
      create: jest.Mock;
      findUnique: jest.Mock;
      findMany: jest.Mock;
      update: jest.Mock;
    };
  };
  let dmGateway: {
    emitMessageNew: jest.Mock;
    emitMessageDelete: jest.Mock;
    emitConversationChanged: jest.Mock;
  };

  const userId = 'user-a';
  const otherUserId = 'user-b';
  const conversationId = 'conversation-1';
  const messageId = 'message-1';
  const createdAt = new Date('2026-01-01T00:00:00.000Z');
  const updatedAt = new Date('2026-01-02T00:00:00.000Z');

  // Prisma-строки с приватными полями: маппер обязан их отбросить.
  function rawUser(id: string) {
    return {
      id,
      username: `name-${id}`,
      avatarUrl: null,
      email: `${id}@plums.test`,
      passwordHash: 'hash',
      status: 'ONLINE',
    };
  }

  function rawMessage(id: string, senderId = otherUserId) {
    return {
      id,
      conversationId,
      senderId,
      content: `content-${id}`,
      createdAt,
      updatedAt: createdAt,
      deletedAt: null,
      sender: rawUser(senderId),
    };
  }

  function rawConversation(messages: unknown[] = []) {
    return {
      id: conversationId,
      userA: userId,
      userB: otherUserId,
      createdAt,
      updatedAt,
      userAPeer: rawUser(userId),
      userBPeer: rawUser(otherUserId),
      messages,
    };
  }

  const expectedConversationKeys = [
    'createdAt',
    'id',
    'lastMessage',
    'updatedAt',
    'userA',
    'userB',
  ];
  const expectedMessageKeys = [
    'content',
    'conversationId',
    'createdAt',
    'id',
    'sender',
    'senderId',
    'updatedAt',
  ];
  const expectedUserKeys = ['avatarUrl', 'id', 'username'];

  beforeEach(async () => {
    prisma = {
      $transaction: jest.fn(),
      user: { findUnique: jest.fn() },
      directConversation: {
        create: jest.fn(),
        findUnique: jest.fn(),
        findMany: jest.fn(),
        update: jest.fn(),
      },
      directMessage: {
        create: jest.fn(),
        findUnique: jest.fn(),
        findMany: jest.fn(),
        update: jest.fn(),
      },
    };
    // Интерактивная транзакция: колбэк получает тот же мок-клиент.
    prisma.$transaction.mockImplementation(
      (callback: (tx: typeof prisma) => unknown) => callback(prisma),
    );
    prisma.user.findUnique.mockResolvedValue({ id: otherUserId });
    dmGateway = {
      emitMessageNew: jest.fn(),
      emitMessageDelete: jest.fn(),
      emitConversationChanged: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        DmService,
        { provide: PrismaService, useValue: prisma },
        { provide: DmGateway, useValue: dmGateway },
      ],
    }).compile();

    service = module.get<DmService>(DmService);
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('mappers', () => {
    it('toDmUser keeps only public fields', () => {
      const user = toDmUser(rawUser(userId));

      expect(Object.keys(user).sort()).toEqual(expectedUserKeys);
      expect(user).not.toHaveProperty('email');
    });

    it('toDmMessage drops deletedAt and private sender fields', () => {
      const message = toDmMessage(rawMessage(messageId));

      expect(Object.keys(message).sort()).toEqual(expectedMessageKeys);
      expect(message).not.toHaveProperty('deletedAt');
      expect(message.sender).not.toHaveProperty('email');
      expect(message.conversationId).toBe(conversationId);
    });

    it('toDmConversation maps peers and lastMessage', () => {
      const conversation = toDmConversation(
        rawConversation([rawMessage(messageId)]) as never,
      );

      expect(Object.keys(conversation).sort()).toEqual(
        expectedConversationKeys,
      );
      expect(conversation.userA).toEqual({
        id: userId,
        username: `name-${userId}`,
        avatarUrl: null,
      });
      expect(conversation.userB.id).toBe(otherUserId);
      expect(Object.keys(conversation.lastMessage!).sort()).toEqual(
        expectedMessageKeys,
      );
      expect(toDmConversation(rawConversation() as never).lastMessage).toBe(
        null,
      );
    });
  });

  describe('getOrCreateConversation', () => {
    it('creates a conversation in canonical order regardless of initiator', async () => {
      prisma.user.findUnique.mockResolvedValue({ id: userId });
      prisma.directConversation.create.mockResolvedValue(rawConversation());

      // Инициатор — пользователь с большим id.
      const result = await service.getOrCreateConversation(otherUserId, {
        userId,
      });

      expect(prisma.directConversation.create).toHaveBeenCalledWith({
        data: { userA: userId, userB: otherUserId },
        include: expect.anything(),
      });
      expect(result.userA.id).toBe(userId);
      expect(result.userB.id).toBe(otherUserId);
      expect(dmGateway.emitConversationChanged).toHaveBeenCalledWith(
        userId,
        conversationId,
      );
    });

    it('returns the same id and canonical order for A->B and B->A', async () => {
      prisma.directConversation.create
        .mockResolvedValueOnce(rawConversation())
        .mockRejectedValueOnce(
          new Prisma.PrismaClientKnownRequestError('Unique constraint failed', {
            code: 'P2002',
            clientVersion: '7.8.0',
          }),
        );
      prisma.directConversation.findUnique.mockResolvedValue(rawConversation());

      const fromA = await service.getOrCreateConversation(userId, {
        userId: otherUserId,
      });
      const fromB = await service.getOrCreateConversation(otherUserId, {
        userId,
      });

      expect(fromB).toEqual(fromA);
      expect(dmGateway.emitConversationChanged).toHaveBeenCalledTimes(1);
      expect(prisma.directConversation.create).toHaveBeenNthCalledWith(
        2,
        expect.objectContaining({
          data: { userA: userId, userB: otherUserId },
        }),
      );
    });

    it('returns the same shape as findConversations', async () => {
      const raw = rawConversation([rawMessage(messageId)]);
      prisma.directConversation.create.mockResolvedValue(raw);
      prisma.directConversation.findMany.mockResolvedValue([raw]);

      const created = await service.getOrCreateConversation(userId, {
        userId: otherUserId,
      });
      const [listed] = await service.findConversations(userId);

      expect(created).toEqual(listed);
      expect(Object.keys(created).sort()).toEqual(expectedConversationKeys);
      expect(typeof created.userA).toBe('object');
      expect(created.userA).not.toHaveProperty('email');
      expect(created.lastMessage?.sender).not.toHaveProperty('email');
      expect(created).not.toHaveProperty('messages');
      expect(created).not.toHaveProperty('userAPeer');
    });

    it('rejects creating a conversation with self', async () => {
      await expect(
        service.getOrCreateConversation(userId, { userId }),
      ).rejects.toThrow(BadRequestException);

      expect(prisma.directConversation.create).not.toHaveBeenCalled();
    });

    it('returns 404 for an unknown peer without touching conversations', async () => {
      prisma.user.findUnique.mockResolvedValue(null);

      await expect(
        service.getOrCreateConversation(userId, { userId: 'missing-user' }),
      ).rejects.toThrow(new NotFoundException('Пользователь не найден'));

      expect(prisma.directConversation.create).not.toHaveBeenCalled();
    });

    it('maps a P2003 race (peer deleted before create) to 404', async () => {
      prisma.directConversation.create.mockRejectedValue(
        new Prisma.PrismaClientKnownRequestError('Foreign key failed', {
          code: 'P2003',
          clientVersion: '7.8.0',
        }),
      );

      await expect(
        service.getOrCreateConversation(userId, { userId: otherUserId }),
      ).rejects.toThrow(new NotFoundException('Пользователь не найден'));
    });

    it('recovers from P2002 race by reading the existing conversation', async () => {
      prisma.directConversation.create.mockRejectedValue(
        new Prisma.PrismaClientKnownRequestError('Unique constraint failed', {
          code: 'P2002',
          clientVersion: '7.8.0',
        }),
      );
      prisma.directConversation.findUnique.mockResolvedValue(rawConversation());

      const result = await service.getOrCreateConversation(userId, {
        userId: otherUserId,
      });

      expect(prisma.directConversation.findUnique).toHaveBeenCalledWith({
        where: { userA_userB: { userA: userId, userB: otherUserId } },
        include: expect.anything(),
      });
      expect(result.id).toBe(conversationId);
      expect(Object.keys(result).sort()).toEqual(expectedConversationKeys);
    });

    it('propagates non-P2002 Prisma errors', async () => {
      prisma.directConversation.create.mockRejectedValue(
        new Prisma.PrismaClientKnownRequestError('Record not found', {
          code: 'P2017',
          clientVersion: '7.8.0',
        }),
      );

      await expect(
        service.getOrCreateConversation(userId, { userId: otherUserId }),
      ).rejects.toThrow(Prisma.PrismaClientKnownRequestError);

      expect(prisma.directConversation.findUnique).not.toHaveBeenCalled();
    });
  });

  describe('findConversations', () => {
    it('returns the user conversations with both participants and the last message', async () => {
      prisma.directConversation.findMany.mockResolvedValue([
        rawConversation([rawMessage(messageId)]),
        { ...rawConversation(), id: 'conversation-2' },
      ]);

      const result = await service.findConversations(userId);

      expect(prisma.directConversation.findMany).toHaveBeenCalledWith({
        where: {
          OR: [{ userA: userId }, { userB: userId }],
        },
        include: expect.objectContaining({
          messages: expect.objectContaining({
            // Удалённые сообщения не становятся lastMessage.
            where: { deletedAt: null },
            take: 1,
          }),
        }),
        orderBy: [{ updatedAt: 'desc' }, { id: 'desc' }],
      });
      expect(result).toHaveLength(2);
      expect(result[0].lastMessage).toMatchObject({
        id: messageId,
        conversationId,
        senderId: otherUserId,
      });
      expect(result[0].lastMessage).not.toHaveProperty('deletedAt');
      expect(result[0].userA).not.toHaveProperty('email');
      expect(result[1].lastMessage).toBeNull();
    });
  });

  describe('findMessages', () => {
    it('returns only participant messages in chronological order', async () => {
      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });

      const older = rawMessage('message-1');
      const newer = rawMessage('message-2');
      prisma.directMessage.findMany.mockResolvedValue([newer, older]);

      const result = await service.findMessages(conversationId, userId);

      expect(prisma.directMessage.findMany).toHaveBeenCalledWith({
        where: { conversationId, deletedAt: null },
        orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
        take: 50,
        select: expect.objectContaining({ conversationId: true }),
      });
      expect(result.map((message) => message.id)).toEqual([
        'message-1',
        'message-2',
      ]);
      expect(Object.keys(result[0]).sort()).toEqual(expectedMessageKeys);
      expect(result[0].sender).not.toHaveProperty('email');
    });

    it('supports the before cursor with a compound (createdAt, id) filter', async () => {
      const cursorCreatedAt = new Date('2026-01-01T00:00:00.000Z');

      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });
      prisma.directMessage.findUnique.mockResolvedValue({
        createdAt: cursorCreatedAt,
        conversationId,
      });
      prisma.directMessage.findMany.mockResolvedValue([]);

      await service.findMessages(conversationId, userId, {
        limit: 10,
        before: 'cursor-message',
      });

      expect(prisma.directMessage.findUnique).toHaveBeenCalledWith({
        where: { id: 'cursor-message' },
        select: { createdAt: true, conversationId: true },
      });
      expect(prisma.directMessage.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            OR: [
              { createdAt: { lt: cursorCreatedAt } },
              {
                createdAt: cursorCreatedAt,
                id: { lt: 'cursor-message' },
              },
            ],
          }),
          take: 10,
        }),
      );
    });

    it('supports the after cursor in ascending order without reverse', async () => {
      const cursorCreatedAt = new Date('2026-01-01T00:00:00.000Z');

      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });
      prisma.directMessage.findUnique.mockResolvedValue({
        createdAt: cursorCreatedAt,
        conversationId,
      });
      prisma.directMessage.findMany.mockResolvedValue([
        rawMessage('message-2'),
        rawMessage('message-3'),
      ]);

      const result = await service.findMessages(conversationId, userId, {
        limit: 10,
        after: 'cursor-message',
      });

      expect(prisma.directMessage.findUnique).toHaveBeenCalledWith({
        where: { id: 'cursor-message' },
        select: { createdAt: true, conversationId: true },
      });
      expect(prisma.directMessage.findMany).toHaveBeenCalledWith({
        where: {
          conversationId,
          deletedAt: null,
          OR: [
            { createdAt: { gt: cursorCreatedAt } },
            {
              createdAt: cursorCreatedAt,
              id: { gt: 'cursor-message' },
            },
          ],
        },
        orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
        take: 10,
        select: expect.objectContaining({ conversationId: true }),
      });
      expect(result.map((message) => message.id)).toEqual([
        'message-2',
        'message-3',
      ]);
      expect(Object.keys(result[0]).sort()).toEqual(expectedMessageKeys);
    });

    it('rejects before and after used together', async () => {
      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });

      await expect(
        service.findMessages(conversationId, userId, {
          before: 'message-1',
          after: 'message-2',
        }),
      ).rejects.toThrow(BadRequestException);

      expect(prisma.directMessage.findUnique).not.toHaveBeenCalled();
      expect(prisma.directMessage.findMany).not.toHaveBeenCalled();
    });

    it('rejects an after cursor from another conversation or missing', async () => {
      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });
      prisma.directMessage.findUnique
        .mockResolvedValueOnce({
          createdAt: new Date(),
          conversationId: 'another-conversation',
        })
        .mockResolvedValueOnce(null);

      await expect(
        service.findMessages(conversationId, userId, {
          after: 'foreign-message',
        }),
      ).rejects.toThrow('Некорректный курсор пагинации');
      await expect(
        service.findMessages(conversationId, userId, {
          after: 'missing-message',
        }),
      ).rejects.toThrow('Некорректный курсор пагинации');

      expect(prisma.directMessage.findMany).not.toHaveBeenCalled();
    });

    it('rejects a cursor message that belongs to another conversation', async () => {
      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });
      prisma.directMessage.findUnique.mockResolvedValue({
        createdAt: new Date(),
        conversationId: 'another-conversation',
      });

      await expect(
        service.findMessages(conversationId, userId, {
          before: 'foreign-message',
        }),
      ).rejects.toThrow(BadRequestException);

      expect(prisma.directMessage.findMany).not.toHaveBeenCalled();
    });

    it('rejects a participant that is not a member', async () => {
      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });

      await expect(
        service.findMessages(conversationId, 'intruder'),
      ).rejects.toThrow(ForbiddenException);
    });

    it('rejects a missing conversation', async () => {
      prisma.directConversation.findUnique.mockResolvedValue(null);

      await expect(
        service.findMessages(conversationId, userId),
      ).rejects.toThrow(NotFoundException);
    });
  });

  describe('sendMessage', () => {
    beforeEach(() => {
      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });
    });

    it('persists the message, bumps conversation updatedAt in one transaction, then emits', async () => {
      const created = rawMessage(messageId, userId);
      prisma.directMessage.create.mockResolvedValue(created);
      prisma.directConversation.update.mockResolvedValue({});

      const result = await service.sendMessage(conversationId, userId, {
        content: 'hello',
      });

      expect(prisma.$transaction).toHaveBeenCalledTimes(1);
      expect(prisma.directMessage.create).toHaveBeenCalledWith({
        data: { conversationId, senderId: userId, content: 'hello' },
        select: expect.objectContaining({ conversationId: true }),
      });
      expect(prisma.directConversation.update).toHaveBeenCalledWith({
        where: { id: conversationId },
        data: { updatedAt: created.createdAt },
      });
      expect(Object.keys(result).sort()).toEqual(expectedMessageKeys);
      expect(result.sender).not.toHaveProperty('email');
      expect(dmGateway.emitMessageNew).toHaveBeenCalledTimes(1);
      expect(dmGateway.emitMessageNew).toHaveBeenCalledWith(
        conversationId,
        result,
      );
      expect(dmGateway.emitConversationChanged).toHaveBeenCalledWith(
        otherUserId,
        conversationId,
      );
      // Эмит вызывается только после записи сообщения и диалога.
      expect(
        prisma.directConversation.update.mock.invocationCallOrder[0],
      ).toBeLessThan(dmGateway.emitMessageNew.mock.invocationCallOrder[0]);
    });

    it('emits only after the transaction is committed', async () => {
      prisma.directMessage.create.mockResolvedValue(rawMessage(messageId));
      prisma.directConversation.update.mockResolvedValue({});
      let committed = false;
      prisma.$transaction.mockImplementation(
        async (callback: (tx: typeof prisma) => unknown) => {
          const value = await callback(prisma);
          expect(dmGateway.emitMessageNew).not.toHaveBeenCalled();
          committed = true;
          return value;
        },
      );
      dmGateway.emitMessageNew.mockImplementation(() => {
        expect(committed).toBe(true);
      });

      await service.sendMessage(conversationId, userId, { content: 'hello' });

      expect(dmGateway.emitMessageNew).toHaveBeenCalledTimes(1);
    });

    it('does not emit when the message write fails', async () => {
      prisma.directMessage.create.mockRejectedValue(new Error('db down'));

      await expect(
        service.sendMessage(conversationId, userId, { content: 'hello' }),
      ).rejects.toThrow('db down');

      expect(prisma.directConversation.update).not.toHaveBeenCalled();
      expect(dmGateway.emitMessageNew).not.toHaveBeenCalled();
    });

    it('does not emit when bumping the conversation fails (rollback)', async () => {
      prisma.directMessage.create.mockResolvedValue(rawMessage(messageId));
      prisma.directConversation.update.mockRejectedValue(new Error('db down'));

      await expect(
        service.sendMessage(conversationId, userId, { content: 'hello' }),
      ).rejects.toThrow('db down');

      expect(dmGateway.emitMessageNew).not.toHaveBeenCalled();
    });

    it('rejects a non-participant sender', async () => {
      await expect(
        service.sendMessage(conversationId, 'intruder', { content: 'hi' }),
      ).rejects.toThrow(ForbiddenException);

      expect(prisma.$transaction).not.toHaveBeenCalled();
      expect(prisma.directMessage.create).not.toHaveBeenCalled();
      expect(dmGateway.emitMessageNew).not.toHaveBeenCalled();
    });
  });

  describe('removeMessage', () => {
    const message = {
      id: messageId,
      conversationId,
      senderId: userId,
      content: 'hello',
      deletedAt: null,
    };

    it('soft-deletes the own message and emits dm:delete only after success', async () => {
      prisma.directMessage.findUnique.mockResolvedValue(message);
      prisma.directMessage.update.mockResolvedValue({ ...message });

      await service.removeMessage(messageId, userId);

      expect(prisma.directMessage.update).toHaveBeenCalledWith({
        where: { id: messageId },
        data: expect.objectContaining({ deletedAt: expect.any(Date) }),
      });
      expect(dmGateway.emitMessageDelete).toHaveBeenCalledWith(conversationId, {
        id: messageId,
      });
      expect(
        prisma.directMessage.update.mock.invocationCallOrder[0],
      ).toBeLessThan(dmGateway.emitMessageDelete.mock.invocationCallOrder[0]);
    });

    it('does not emit dm:delete when the soft-delete write fails', async () => {
      prisma.directMessage.findUnique.mockResolvedValue(message);
      prisma.directMessage.update.mockRejectedValue(new Error('db down'));

      await expect(service.removeMessage(messageId, userId)).rejects.toThrow(
        'db down',
      );

      expect(dmGateway.emitMessageDelete).not.toHaveBeenCalled();
    });

    it('rejects deleting another user message', async () => {
      prisma.directMessage.findUnique.mockResolvedValue({
        ...message,
        senderId: otherUserId,
      });

      await expect(service.removeMessage(messageId, userId)).rejects.toThrow(
        ForbiddenException,
      );

      expect(prisma.directMessage.update).not.toHaveBeenCalled();
      expect(dmGateway.emitMessageDelete).not.toHaveBeenCalled();
    });

    it('rejects deleting a missing message', async () => {
      prisma.directMessage.findUnique.mockResolvedValue(null);

      await expect(service.removeMessage(messageId, userId)).rejects.toThrow(
        NotFoundException,
      );
    });

    it('rejects deleting an already deleted message', async () => {
      prisma.directMessage.findUnique.mockResolvedValue({
        ...message,
        deletedAt: new Date(),
      });

      await expect(service.removeMessage(messageId, userId)).rejects.toThrow(
        NotFoundException,
      );

      expect(prisma.directMessage.update).not.toHaveBeenCalled();
    });
  });
});
