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

// Единый публичный контракт DM (см. docs/DM_API.md). Наружу уходят только
// эти формы: без email/passwordHash и без deletedAt.
export type DmUser = {
  id: string;
  username: string;
  avatarUrl: string | null;
};

export type DmMessage = {
  id: string;
  conversationId: string;
  senderId: string;
  content: string;
  createdAt: Date;
  updatedAt: Date;
  sender: DmUser;
};

export type DmConversation = {
  id: string;
  createdAt: Date;
  updatedAt: Date;
  userA: DmUser;
  userB: DmUser;
  lastMessage: DmMessage | null;
};

const publicUserSelect = {
  id: true,
  username: true,
  avatarUrl: true,
} satisfies Prisma.UserSelect;

const dmMessageSelect = {
  id: true,
  conversationId: true,
  senderId: true,
  content: true,
  createdAt: true,
  updatedAt: true,
  sender: { select: publicUserSelect },
} satisfies Prisma.DirectMessageSelect;

const conversationInclude = {
  userAPeer: { select: publicUserSelect },
  userBPeer: { select: publicUserSelect },
  messages: {
    where: { deletedAt: null },
    orderBy: [{ createdAt: 'desc' as const }, { id: 'desc' as const }],
    take: 1,
    select: dmMessageSelect,
  },
} satisfies Prisma.DirectConversationInclude;

// Мапперы явно перечисляют поля: лишнее поле из Prisma не утечёт наружу,
// даже если select/include когда-нибудь расширят.
export function toDmUser(user: DmUser): DmUser {
  return {
    id: user.id,
    username: user.username,
    avatarUrl: user.avatarUrl ?? null,
  };
}

export function toDmMessage(message: DmMessage): DmMessage {
  return {
    id: message.id,
    conversationId: message.conversationId,
    senderId: message.senderId,
    content: message.content,
    createdAt: message.createdAt,
    updatedAt: message.updatedAt,
    sender: toDmUser(message.sender),
  };
}

export function toDmConversation(conversation: {
  id: string;
  createdAt: Date;
  updatedAt: Date;
  userAPeer: DmUser;
  userBPeer: DmUser;
  messages: DmMessage[];
}): DmConversation {
  const lastMessage = conversation.messages[0];

  return {
    id: conversation.id,
    createdAt: conversation.createdAt,
    updatedAt: conversation.updatedAt,
    userA: toDmUser(conversation.userAPeer),
    userB: toDmUser(conversation.userBPeer),
    lastMessage: lastMessage ? toDmMessage(lastMessage) : null,
  };
}

@Injectable()
export class DmService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly dmGateway: DmGateway,
  ) {}

  async getOrCreateConversation(
    userId: string,
    dto: CreateDmConversationDto,
  ): Promise<DmConversation> {
    if (dto.userId === userId) {
      throw new BadRequestException('Нельзя создать диалог с самим собой');
    }

    const peer = await this.prisma.user.findUnique({
      where: { id: dto.userId },
      select: { id: true },
    });

    if (!peer) {
      throw new NotFoundException('Пользователь не найден');
    }

    // Канонический порядок участников: пара уникальна независимо от того,
    // кто начал диалог.
    const userA = userId < dto.userId ? userId : dto.userId;
    const userB = userId < dto.userId ? dto.userId : userId;

    try {
      const created = await this.prisma.directConversation.create({
        data: { userA, userB },
        include: conversationInclude,
      });

      this.dmGateway.emitConversationChanged(dto.userId, created.id);
      return toDmConversation(created);
    } catch (error) {
      // Пользователь удалён между проверкой и созданием: FK-ошибка → 404.
      if (this.isPrismaError(error, 'P2003')) {
        throw new NotFoundException('Пользователь не найден');
      }

      // Параллельное создание одной и той же пары: P2002 — перечитываем
      // уже созданный диалог (идемпотентность).
      if (this.isPrismaError(error, 'P2002')) {
        const existing = await this.prisma.directConversation.findUnique({
          where: {
            userA_userB: { userA, userB },
          },
          include: conversationInclude,
        });

        if (existing) {
          return toDmConversation(existing);
        }

        throw new NotFoundException('Диалог не найден');
      }

      throw error;
    }
  }

  async findConversations(userId: string): Promise<DmConversation[]> {
    const conversations = await this.prisma.directConversation.findMany({
      where: {
        OR: [{ userA: userId }, { userB: userId }],
      },
      include: conversationInclude,
      orderBy: [{ updatedAt: 'desc' }, { id: 'desc' }],
    });

    return conversations.map(toDmConversation);
  }

  async findMessages(
    conversationId: string,
    userId: string,
    options?: { limit?: number; before?: string; after?: string },
  ): Promise<DmMessage[]> {
    await this.getConversationForUser(conversationId, userId);

    const limit = options?.limit ?? 50;

    if (options?.before && options?.after) {
      throw new BadRequestException(
        'Нельзя одновременно использовать курсоры before и after',
      );
    }

    let cursorFilter:
      | {
          OR: [
            { createdAt: { lt: Date } },
            { createdAt: Date; id: { lt: string } },
          ];
        }
      | {
          OR: [
            { createdAt: { gt: Date } },
            { createdAt: Date; id: { gt: string } },
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
    } else if (options?.after) {
      // Курсор ищется без фильтра deletedAt: удаление сообщения-курсора
      // не должно ломать догрузку после переподключения.
      const cursorMessage = await this.prisma.directMessage.findUnique({
        where: { id: options.after },
        select: { createdAt: true, conversationId: true },
      });

      if (!cursorMessage || cursorMessage.conversationId !== conversationId) {
        throw new BadRequestException('Некорректный курсор пагинации');
      }

      cursorFilter = {
        OR: [
          { createdAt: { gt: cursorMessage.createdAt } },
          { createdAt: cursorMessage.createdAt, id: { gt: options.after } },
        ],
      };
    }

    const messages = await this.prisma.directMessage.findMany({
      where: {
        conversationId,
        deletedAt: null,
        ...cursorFilter,
      },
      orderBy: options?.after
        ? [{ createdAt: 'asc' }, { id: 'asc' }]
        : [{ createdAt: 'desc' }, { id: 'desc' }],
      take: limit,
      select: dmMessageSelect,
    });

    if (options?.after) {
      // Курсор «вперёд»: Prisma уже отдаёт страницу от старых к новым.
      return messages.map(toDmMessage);
    }

    // Хронологический порядок: от старых к новым.
    return messages.reverse().map(toDmMessage);
  }

  async sendMessage(
    conversationId: string,
    userId: string,
    dto: SendDmMessageDto,
  ): Promise<DmMessage> {
    const conversation = await this.getConversationForUser(
      conversationId,
      userId,
    );

    // Сообщение и updatedAt диалога пишутся атомарно: список диалогов
    // сортируется по updatedAt, т.е. по последней активности.
    const message = await this.prisma.$transaction(async (tx) => {
      const created = await tx.directMessage.create({
        data: {
          conversationId,
          senderId: userId,
          content: dto.content,
        },
        select: dmMessageSelect,
      });

      await tx.directConversation.update({
        where: { id: conversationId },
        data: { updatedAt: created.createdAt },
      });

      return toDmMessage(created);
    });

    // Realtime-событие уходит только после коммита транзакции.
    this.dmGateway.emitMessageNew(conversationId, message);
    const recipientId =
      conversation.userA === userId ? conversation.userB : conversation.userA;
    this.dmGateway.emitConversationChanged(recipientId, conversationId);

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

  private isPrismaError(error: unknown, code: string) {
    return (
      error instanceof Prisma.PrismaClientKnownRequestError &&
      error.code === code
    );
  }
}
