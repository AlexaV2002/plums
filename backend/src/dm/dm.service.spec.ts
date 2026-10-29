import {
  BadRequestException,
  ForbiddenException,
  NotFoundException,
} from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { DmGateway } from './dm.gateway';
import { DmService } from './dm.service';

describe('DmService', () => {
  let service: DmService;
  let prisma: {
    directConversation: {
      create: jest.Mock;
      findUnique: jest.Mock;
      findMany: jest.Mock;
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
  };

  const userId = 'user-a';
  const otherUserId = 'user-b';
  const conversationId = 'conversation-1';
  const messageId = 'message-1';

  beforeEach(async () => {
    prisma = {
      directConversation: {
        create: jest.fn(),
        findUnique: jest.fn(),
        findMany: jest.fn(),
      },
      directMessage: {
        create: jest.fn(),
        findUnique: jest.fn(),
        findMany: jest.fn(),
        update: jest.fn(),
      },
    };
    dmGateway = {
      emitMessageNew: jest.fn(),
      emitMessageDelete: jest.fn(),
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

  describe('getOrCreateConversation', () => {
    it('creates a conversation in canonical order regardless of initiator', async () => {
      const created = {
        id: conversationId,
        userA: userId,
        userB: otherUserId,
        messages: [],
      };

      prisma.directConversation.create.mockResolvedValue(created);

      // Инициатор — пользователь с большим id.
      const result = await service.getOrCreateConversation(otherUserId, {
        userId,
      });

      expect(prisma.directConversation.create).toHaveBeenCalledWith({
        data: { userA: userId, userB: otherUserId },
        include: expect.anything(),
      });
      expect(result).toBe(created);
    });

    it('rejects creating a conversation with self', async () => {
      await expect(
        service.getOrCreateConversation(userId, { userId }),
      ).rejects.toThrow(BadRequestException);

      expect(prisma.directConversation.create).not.toHaveBeenCalled();
    });

    it('recovers from P2002 race by reading the existing conversation', async () => {
      const existing = {
        id: conversationId,
        userA: userId,
        userB: otherUserId,
        messages: [],
      };

      prisma.directConversation.create.mockRejectedValue(
        new Prisma.PrismaClientKnownRequestError('Unique constraint failed', {
          code: 'P2002',
          clientVersion: '7.8.0',
        }),
      );
      prisma.directConversation.findUnique.mockResolvedValue(existing);

      const result = await service.getOrCreateConversation(userId, {
        userId: otherUserId,
      });

      expect(prisma.directConversation.findUnique).toHaveBeenCalledWith({
        where: { userA_userB: { userA: userId, userB: otherUserId } },
        include: expect.anything(),
      });
      expect(result).toBe(existing);
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
        {
          id: conversationId,
          createdAt: new Date(),
          updatedAt: new Date(),
          userA: {
            id: userId,
            username: 'user_a',
            avatarUrl: null,
            status: 'online',
          },
          userB: {
            id: otherUserId,
            username: 'user_b',
            avatarUrl: null,
            status: 'offline',
          },
          messages: [
            {
              id: messageId,
              senderId: otherUserId,
              content: 'hello',
              createdAt: new Date(),
              updatedAt: new Date(),
              sender: {
                id: otherUserId,
                username: 'user_b',
                avatarUrl: null,
                status: 'offline',
              },
            },
          ],
        },
        {
          id: 'conversation-2',
          createdAt: new Date(),
          updatedAt: new Date(),
          userA: { id: userId, username: 'user_a', avatarUrl: null, status: 'online' },
          userB: { id: 'user-c', username: 'user_c', avatarUrl: null, status: 'offline' },
          messages: [],
        },
      ]);

      const result = await service.findConversations(userId);

      expect(prisma.directConversation.findMany).toHaveBeenCalledWith({
        where: {
          OR: [{ userA: userId }, { userB: userId }],
        },
        include: expect.objectContaining({
          messages: expect.objectContaining({
            where: { deletedAt: null },
            take: 1,
          }),
        }),
        orderBy: [{ updatedAt: 'desc' }, { id: 'desc' }],
      });
      expect(result).toHaveLength(2);
      expect(result[0].lastMessage).toMatchObject({
        id: messageId,
        senderId: otherUserId,
      });
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

      const older = { id: 'message-1', content: 'older' };
      const newer = { id: 'message-2', content: 'newer' };
      prisma.directMessage.findMany.mockResolvedValue([newer, older]);

      const result = await service.findMessages(conversationId, userId);

      expect(prisma.directMessage.findMany).toHaveBeenCalledWith({
        where: { conversationId, deletedAt: null },
        orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
        take: 50,
        include: expect.anything(),
      });
      expect(result).toEqual([older, newer]);
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
    it('persists the message and emits dm:new only after success', async () => {
      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });
      const created = {
        id: messageId,
        conversationId,
        senderId: userId,
        content: 'hello',
        createdAt: new Date(),
        updatedAt: new Date(),
      };
      prisma.directMessage.create.mockImplementation(async () => {
        return created;
      });

      const result = await service.sendMessage(conversationId, userId, {
        content: 'hello',
      });

      expect(result).toBe(created);
      expect(dmGateway.emitMessageNew).toHaveBeenCalledTimes(1);
      expect(dmGateway.emitMessageNew).toHaveBeenCalledWith(
        conversationId,
        created,
      );
      // Эмит вызывается только после успешной записи.
      expect(
        prisma.directMessage.create.mock.invocationCallOrder[0],
      ).toBeLessThan(
        dmGateway.emitMessageNew.mock.invocationCallOrder[0],
      );
    });

    it('does not emit when the write fails', async () => {
      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });
      prisma.directMessage.create.mockRejectedValue(new Error('db down'));

      await expect(
        service.sendMessage(conversationId, userId, { content: 'hello' }),
      ).rejects.toThrow('db down');

      expect(dmGateway.emitMessageNew).not.toHaveBeenCalled();
    });

    it('rejects a non-participant sender', async () => {
      prisma.directConversation.findUnique.mockResolvedValue({
        id: conversationId,
        userA: userId,
        userB: otherUserId,
      });

      await expect(
        service.sendMessage(conversationId, 'intruder', { content: 'hi' }),
      ).rejects.toThrow(ForbiddenException);

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
      ).toBeLessThan(
        dmGateway.emitMessageDelete.mock.invocationCallOrder[0],
      );
    });

    it('rejects deleting another user message', async () => {
      prisma.directMessage.findUnique.mockResolvedValue({
        ...message,
        senderId: otherUserId,
      });

      await expect(
        service.removeMessage(messageId, userId),
      ).rejects.toThrow(ForbiddenException);

      expect(prisma.directMessage.update).not.toHaveBeenCalled();
      expect(dmGateway.emitMessageDelete).not.toHaveBeenCalled();
    });

    it('rejects deleting a missing message', async () => {
      prisma.directMessage.findUnique.mockResolvedValue(null);

      await expect(
        service.removeMessage(messageId, userId),
      ).rejects.toThrow(NotFoundException);
    });

    it('rejects deleting an already deleted message', async () => {
      prisma.directMessage.findUnique.mockResolvedValue({
        ...message,
        deletedAt: new Date(),
      });

      await expect(
        service.removeMessage(messageId, userId),
      ).rejects.toThrow(NotFoundException);

      expect(prisma.directMessage.update).not.toHaveBeenCalled();
    });
  });
});
