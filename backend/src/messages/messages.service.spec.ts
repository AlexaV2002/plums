import { BadRequestException, ForbiddenException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { ChannelType } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { MessagesGateway } from './messages.gateway';
import { MessagesService } from './messages.service';

describe('MessagesService', () => {
  let service: MessagesService;
  let prisma: {
    channel: { findUnique: jest.Mock };
    serverMember: { findUnique: jest.Mock };
    message: { findUnique: jest.Mock; findMany: jest.Mock; update: jest.Mock };
  };

  const channelId = 'channel-1';
  const userId = 'user-1';

  beforeEach(async () => {
    prisma = {
      channel: { findUnique: jest.fn() },
      serverMember: { findUnique: jest.fn() },
      message: { findUnique: jest.fn(), findMany: jest.fn(), update: jest.fn() },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        MessagesService,
        { provide: PrismaService, useValue: prisma },
        {
          provide: MessagesGateway,
          useValue: { emitMessageUpdate: jest.fn(), emitMessageDelete: jest.fn() },
        },
      ],
    }).compile();

    service = module.get<MessagesService>(MessagesService);

    prisma.channel.findUnique.mockResolvedValue({
      id: channelId,
      type: ChannelType.TEXT,
      permissions: null,
      serverId: 'server-1',
      server: { ownerId: userId },
    });
    prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-1' });
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('findByChannel', () => {
    it('возвращает сообщения после курсора after в хронологическом порядке', async () => {
      prisma.message.findUnique.mockResolvedValue({
        createdAt: new Date('2024-01-01T00:00:00Z'),
        channelId,
      });
      const found = [
        { id: 'm2', createdAt: new Date('2024-01-01T00:00:01Z') },
        { id: 'm3', createdAt: new Date('2024-01-01T00:00:02Z') },
      ];
      prisma.message.findMany.mockResolvedValue(found);

      const result = await service.findByChannel(channelId, userId, {
        after: 'm1',
      });

      expect(prisma.message.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            channelId,
            OR: [
              { createdAt: { gt: new Date('2024-01-01T00:00:00Z') } },
              {
                createdAt: new Date('2024-01-01T00:00:00Z'),
                id: { gt: 'm1' },
              },
            ],
          }),
          orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
        }),
      );
      expect(result).toBe(found);
    });

    it('передаёт limit дальше в Prisma для курсора after', async () => {
      prisma.message.findUnique.mockResolvedValue({
        createdAt: new Date('2024-01-01T00:00:00Z'),
        channelId,
      });
      prisma.message.findMany.mockResolvedValue([]);

      await service.findByChannel(channelId, userId, {
        after: 'm1',
        limit: 10,
      });

      expect(prisma.message.findMany).toHaveBeenCalledWith(
        expect.objectContaining({ take: 10 }),
      );
    });

    it('выбрасывает BadRequestException, если курсор after не найден', async () => {
      prisma.message.findUnique.mockResolvedValue(null);

      await expect(
        service.findByChannel(channelId, userId, { after: 'missing' }),
      ).rejects.toThrow(BadRequestException);
    });

    it('выбрасывает BadRequestException, если курсор after принадлежит другому каналу', async () => {
      prisma.message.findUnique.mockResolvedValue({
        createdAt: new Date(),
        channelId: 'other-channel',
      });

      await expect(
        service.findByChannel(channelId, userId, { after: 'm1' }),
      ).rejects.toThrow(BadRequestException);
    });

    it('выбрасывает BadRequestException при одновременной передаче before и after', async () => {
      await expect(
        service.findByChannel(channelId, userId, {
          before: 'm1',
          after: 'm2',
        }),
      ).rejects.toThrow(BadRequestException);

      expect(prisma.message.findUnique).not.toHaveBeenCalled();
    });
  });

  const messageId = 'message-1';
  const authorId = userId;
  const ownerId = 'owner-1';

  const buildMessage = (overrides: Record<string, unknown> = {}) => ({
    id: messageId,
    authorId,
    deletedAt: null,
    channelId,
    channel: {
      id: channelId,
      serverId: 'server-1',
      permissions: null,
      server: { ownerId },
    },
    ...overrides,
  });

  describe('update', () => {
    it('действующий участник редактирует своё сообщение — успешно', async () => {
      prisma.message.findUnique.mockResolvedValue(buildMessage());
      prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-1' });
      prisma.message.update.mockResolvedValue({ id: messageId, channelId });

      await expect(
        service.update(messageId, authorId, { content: 'новый текст' }),
      ).resolves.toBeDefined();

      expect(prisma.message.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: messageId },
          data: { content: 'новый текст' },
        }),
      );
    });

    it('пользователь без ServerMember (kick/ban/leave) не может редактировать своё старое сообщение', async () => {
      prisma.message.findUnique.mockResolvedValue(buildMessage());
      prisma.serverMember.findUnique.mockResolvedValue(null);

      await expect(
        service.update(messageId, authorId, { content: 'x' }),
      ).rejects.toThrow(new ForbiddenException('Вы не состоите на этом сервере'));

      expect(prisma.message.update).not.toHaveBeenCalled();
    });

    it('чужое сообщение — ForbiddenException до проверки членства', async () => {
      prisma.message.findUnique.mockResolvedValue(
        buildMessage({ authorId: 'other-user' }),
      );

      await expect(
        service.update(messageId, userId, { content: 'x' }),
      ).rejects.toThrow(
        new ForbiddenException('Можно редактировать только свои сообщения'),
      );

      expect(prisma.serverMember.findUnique).not.toHaveBeenCalled();
      expect(prisma.message.update).not.toHaveBeenCalled();
    });

    it('скрытый канал (canView:false) блокирует действующего участника без прав', async () => {
      prisma.message.findUnique.mockResolvedValue(
        buildMessage({
          channel: {
            id: channelId,
            serverId: 'server-1',
            permissions: { canView: false, canSendMessages: false },
            server: { ownerId },
          },
        }),
      );
      prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-1' });

      await expect(
        service.update(messageId, authorId, { content: 'x' }),
      ).rejects.toThrow(ForbiddenException);

      expect(prisma.message.update).not.toHaveBeenCalled();
    });

    it('владелец сервера редактирует своё сообщение в канале с canView:false/canSendMessages:false — успешно', async () => {
      prisma.message.findUnique.mockResolvedValue(
        buildMessage({
          authorId: ownerId,
          channel: {
            id: channelId,
            serverId: 'server-1',
            permissions: { canView: false, canSendMessages: false },
            server: { ownerId },
          },
        }),
      );
      prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-owner' });
      prisma.message.update.mockResolvedValue({ id: messageId, channelId });

      await expect(
        service.update(messageId, ownerId, { content: 'x' }),
      ).resolves.toBeDefined();

      expect(prisma.message.update).toHaveBeenCalled();
    });
  });

  describe('remove', () => {
    it('действующий участник удаляет своё сообщение — успешно', async () => {
      prisma.message.findUnique.mockResolvedValue(buildMessage());
      prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-1' });
      prisma.message.update.mockResolvedValue({ id: messageId, channelId });

      await expect(service.remove(messageId, authorId)).resolves.toBeDefined();

      expect(prisma.message.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: messageId },
          data: { deletedAt: expect.any(Date) },
        }),
      );
    });

    it('пользователь без ServerMember (kick/ban/leave) не может удалить своё старое сообщение', async () => {
      prisma.message.findUnique.mockResolvedValue(buildMessage());
      prisma.serverMember.findUnique.mockResolvedValue(null);

      await expect(service.remove(messageId, authorId)).rejects.toThrow(
        new ForbiddenException('Вы не состоите на этом сервере'),
      );

      expect(prisma.message.update).not.toHaveBeenCalled();
    });

    it('чужое сообщение — ForbiddenException до проверки членства', async () => {
      prisma.message.findUnique.mockResolvedValue(
        buildMessage({ authorId: 'other-user' }),
      );

      await expect(service.remove(messageId, userId)).rejects.toThrow(
        new ForbiddenException('Можно удалять только свои сообщения'),
      );

      expect(prisma.serverMember.findUnique).not.toHaveBeenCalled();
      expect(prisma.message.update).not.toHaveBeenCalled();
    });

    it('скрытый канал (canView:false) блокирует действующего участника без прав', async () => {
      prisma.message.findUnique.mockResolvedValue(
        buildMessage({
          channel: {
            id: channelId,
            serverId: 'server-1',
            permissions: { canView: false, canSendMessages: false },
            server: { ownerId },
          },
        }),
      );
      prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-1' });

      await expect(service.remove(messageId, authorId)).rejects.toThrow(
        ForbiddenException,
      );

      expect(prisma.message.update).not.toHaveBeenCalled();
    });

    it('владелец сервера удаляет своё сообщение в канале с canView:false/canSendMessages:false — успешно', async () => {
      prisma.message.findUnique.mockResolvedValue(
        buildMessage({
          authorId: ownerId,
          channel: {
            id: channelId,
            serverId: 'server-1',
            permissions: { canView: false, canSendMessages: false },
            server: { ownerId },
          },
        }),
      );
      prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-owner' });
      prisma.message.update.mockResolvedValue({ id: messageId, channelId });

      await expect(service.remove(messageId, ownerId)).resolves.toBeDefined();

      expect(prisma.message.update).toHaveBeenCalled();
    });
  });
});
