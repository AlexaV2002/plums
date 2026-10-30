import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { CreateDmConversationDto } from './dto/create-dm-conversation.dto';
import { SendDmMessageDto } from './dto/send-dm-message.dto';
import { DmGateway } from './dm.gateway';

const publicUserSelect = {
  id: true,
  username: true,
  avatarUrl: true,
};

const conversationInclude = {
  userAPeer: { select: publicUserSelect },
  userBPeer: { select: publicUserSelect },
  messages: {
    where: { deletedAt: null },
    orderBy: [{ createdAt: 'desc' as const }, { id: 'desc' as const }],
    take: 1,
    select: {
      id: true,
      senderId: true,
      content: true,
      createdAt: true,
      updatedAt: true,
      sender: { select: publicUserSelect },
    },
  },
};

@Injectable()
export class DmService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly dmGateway: DmGateway,
  ) {}

  async getOrCreateConversation(userId: string, dto: CreateDmConversationDto) {
    if (dto.userId === userId) {
      throw new BadRequestException('Нельзя создать диалог с самим собой');
    }

    // Канонический порядок участников: пара уникальна независимо от того,
    // кто начал диалог.
    const userA = userId < dto.userId ? userId : dto.userId;
    const userB = userId < dto.userId ? dto.userId : userId;

    try {
      return await this.prisma.directConversation.create({
        data: { userA, userB },
        include: conversationInclude,
      });
    } catch (error) {
      // Параллельное создание одной и той же пары: P2002 — перечитываем
      // уже созданный диалог (идемпотентность).
      if (this.isUniqueConstraintError(error)) {
        const existing = await this.prisma.directConversation.findUnique({
          where: {
            userA_userB: { userA, userB },
          },
          include: conversationInclude,
        });

        if (existing) {
          return existing;
        }

        throw new NotFoundException('Диалог не найден');
      }

      throw error;
    }
  }

  async findConversations(userId: string) {
    const conversations = await this.prisma.directConversation.findMany({
      where: {
        OR: [{ userA: userId }, { userB: userId }],
      },
      include: conversationInclude,
      orderBy: [{ updatedAt: 'desc' }, { id: 'desc' }],
    });

    return conversations.map((conversation) => ({
      id: conversation.id,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      userA: conversation.userAPeer,
      userB: conversation.userBPeer,
      lastMessage: conversation.messages[0] ?? null,
    }));
  }

  async findMessages(
    conversationId: string,
    userId: string,
    options?: { limit?: number; before?: string },
  ) {
    await this.getConversationForUser(conversationId, userId);

    const limit = options?.limit ?? 50;

    let cursorFilter:
      | {
          OR: [
            { createdAt: { lt: Date } },
            { createdAt: Date; id: { lt: string } },
          ];
        }
      | undefined;

    if (options?.before) {
      const cursorMessage = await this.prisma.directMessage.findUnique({
        where: { id: options.before },
        select: { createdAt: true, conversationId: true },
      });

      if (!cursorMessage || cursorMessage.conversationId !== conversationId) {
        throw new BadRequestException('Некорректный курсор пагинации');
      }

      // Составной курсор (createdAt, id): защита от потери сообщений
      // с одинаковым createdAt на границе страницы.
      cursorFilter = {
        OR: [
          { createdAt: { lt: cursorMessage.createdAt } },
          { createdAt: cursorMessage.createdAt, id: { lt: options.before } },
        ],
      };
    }

    const messages = await this.prisma.directMessage.findMany({
      where: {
        conversationId,
        deletedAt: null,
        ...cursorFilter,
      },
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      take: limit,
      include: {
        sender: { select: publicUserSelect },
      },
    });

    // Хронологический порядок: от старых к новым.
    return messages.reverse();
  }

  async sendMessage(
    conversationId: string,
    userId: string,
    dto: SendDmMessageDto,
  ) {
    await this.getConversationForUser(conversationId, userId);

    const message = await this.prisma.directMessage.create({
      data: {
        conversationId,
        senderId: userId,
        content: dto.content,
      },
      include: {
        sender: { select: publicUserSelect },
      },
    });

    // Realtime-событие уходит только после успешной записи в БД.
    this.dmGateway.emitMessageNew(conversationId, message);

    return message;
  }

  async removeMessage(messageId: string, userId: string) {
    const message = await this.prisma.directMessage.findUnique({
      where: { id: messageId },
    });

    if (!message || message.deletedAt) {
      throw new NotFoundException('Сообщение не найдено');
    }

    if (message.senderId !== userId) {
      throw new ForbiddenException('Можно удалять только свои сообщения');
    }

    await this.prisma.directMessage.update({
      where: { id: messageId },
      data: { deletedAt: new Date() },
    });

    // Realtime-событие уходит только после успешной записи в БД.
    this.dmGateway.emitMessageDelete(message.conversationId, { id: messageId });
  }

  private async getConversationForUser(conversationId: string, userId: string) {
    const conversation = await this.prisma.directConversation.findUnique({
      where: { id: conversationId },
    });

    if (!conversation) {
      throw new NotFoundException('Диалог не найден');
    }

    if (conversation.userA !== userId && conversation.userB !== userId) {
      throw new ForbiddenException('Вы не участник этого диалога');
    }

    return conversation;
  }

  private isUniqueConstraintError(error: unknown) {
    return (
      error instanceof Prisma.PrismaClientKnownRequestError &&
      error.code === 'P2002'
    );
  }
}
