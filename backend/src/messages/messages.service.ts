import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { ChannelType, Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { CreateMessageDto } from './dto/create-message.dto';
import { MessagesGateway } from './messages.gateway';
import { UpdateMessageDto } from './dto/update-message.dto';

type ChannelPermissions = {
  canView?: boolean;
  canSendMessages?: boolean;
  canConnect?: boolean;
};

const messageRelations = {
  author: {
    select: {
      id: true,
      username: true,
      avatarUrl: true,
      status: true,
    },
  },
  attachments: {
    select: { id: true, originalName: true, mimeType: true, sizeBytes: true },
    orderBy: [{ createdAt: 'asc' as const }, { id: 'asc' as const }],
  },
} satisfies Prisma.MessageInclude;

@Injectable()
export class MessagesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly messagesGateway: MessagesGateway,
  ) {}

  private getPermissions(raw: unknown): Required<ChannelPermissions> {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      return {
        canView: true,
        canSendMessages: true,
        canConnect: true,
      };
    }

    const permissions = raw as ChannelPermissions;

    return {
      canView: permissions.canView ?? true,
      canSendMessages: permissions.canSendMessages ?? true,
      canConnect: permissions.canConnect ?? true,
    };
  }

  private async getChannelForUser(channelId: string, userId: string) {
    const channel = await this.prisma.channel.findUnique({
      where: {
        id: channelId,
      },
      include: {
        server: true,
      },
    });

    if (!channel) {
      throw new NotFoundException('Канал не найден');
    }

    const member = await this.prisma.serverMember.findUnique({
      where: {
        serverId_userId: {
          serverId: channel.serverId,
          userId,
        },
      },
    });

    if (!member) {
      throw new ForbiddenException('Вы не состоите на этом сервере');
    }

    return channel;
  }

  private isServerOwner(
    channel: Awaited<ReturnType<MessagesService['getChannelForUser']>>,
    userId: string,
  ) {
    return channel.server.ownerId === userId;
  }

  async create(channelId: string, userId: string, dto: CreateMessageDto) {
    const attachmentIds = dto.attachmentIds ?? [];
    if (
      attachmentIds.length > 4 ||
      new Set(attachmentIds).size !== attachmentIds.length
    ) {
      throw new BadRequestException(
        'Можно прикрепить до четырёх разных изображений',
      );
    }
    const channel = await this.getChannelForUser(channelId, userId);

    if (channel.type !== ChannelType.TEXT) {
      throw new BadRequestException(
        'Сообщения можно отправлять только в текстовый канал',
      );
    }

    const isOwner = this.isServerOwner(channel, userId);
    const permissions = this.getPermissions(channel.permissions);

    if (!isOwner && !permissions.canView) {
      throw new ForbiddenException('У вас нет доступа к этому каналу');
    }

    if (!isOwner && !permissions.canSendMessages) {
      throw new ForbiddenException('В этом канале нельзя отправлять сообщения');
    }

    const clientMessageId = dto.clientMessageId;
    const findExisting = (id: string) =>
      this.prisma.message.findUnique({
        where: {
          authorId_channelId_clientMessageId: {
            authorId: userId,
            channelId,
            clientMessageId: id,
          },
        },
        include: messageRelations,
      });
    const returnExisting = async (id: string) => {
      const existing = await findExisting(id);
      if (!existing) return null;
      const existingIds = (existing.attachments ?? [])
        .map((item) => item.id)
        .sort();
      const requestedIds = [...attachmentIds].sort();
      if (
        existing.content !== dto.content ||
        existing.deletedAt ||
        existingIds.length !== requestedIds.length ||
        existingIds.some((item, index) => item !== requestedIds[index])
      ) {
        throw new ConflictException(
          'Идентификатор уже использован для другого или удалённого сообщения',
        );
      }
      return existing;
    };

    if (clientMessageId) {
      const existing = await returnExisting(clientMessageId);
      if (existing) return existing;
    }

    if (
      (!dto.content || dto.content.length === 0) &&
      attachmentIds.length === 0
    ) {
      throw new BadRequestException('Добавьте текст или изображение');
    }

    try {
      const data = {
        channelId,
        authorId: userId,
        clientMessageId,
        content: dto.content,
      };
      const message =
        attachmentIds.length === 0
          ? await this.prisma.message.create({
              data,
              include: messageRelations,
            })
          : await this.prisma.$transaction(async (tx) => {
              // Hold the channel and membership rows while validating the current
              // permissions and attaching files, so concurrent revocation cannot
              // slip between the access check and the commit.
              await tx.$queryRaw`SELECT "id" FROM "channels" WHERE "id" = ${channelId} FOR SHARE`;
              const current = await tx.channel.findUnique({
                where: { id: channelId },
                include: { server: { select: { ownerId: true } } },
              });
              if (!current) throw new NotFoundException('Канал не найден');
              await tx.$queryRaw`SELECT "id" FROM "server_members" WHERE "serverId" = ${current.serverId} AND "userId" = ${userId} FOR SHARE`;
              const member = await tx.serverMember.findUnique({
                where: {
                  serverId_userId: { serverId: current.serverId, userId },
                },
                select: { id: true },
              });
              if (!member)
                throw new ForbiddenException('Вы не состоите на этом сервере');
              const currentPermissions = this.getPermissions(
                current.permissions,
              );
              if (current.type !== ChannelType.TEXT)
                throw new BadRequestException(
                  'Сообщения можно отправлять только в текстовый канал',
                );
              if (
                current.server.ownerId !== userId &&
                (!currentPermissions.canView ||
                  !currentPermissions.canSendMessages)
              ) {
                throw new ForbiddenException(
                  'У вас нет доступа к этому каналу',
                );
              }
              // Conditional update locks each attachment, preventing parallel reuse.
              const created = await tx.message.create({
                data,
                select: { id: true },
              });
              const linked = await tx.attachment.updateMany({
                where: {
                  id: { in: attachmentIds },
                  ownerId: userId,
                  channelId,
                  state: 'UPLOADED',
                  messageId: null,
                  expiresAt: { gt: new Date() },
                },
                data: {
                  state: 'ATTACHED',
                  messageId: created.id,
                  expiresAt: null,
                },
              });
              if (linked.count !== attachmentIds.length) {
                throw new BadRequestException(
                  'Вложение недоступно, истекло или уже использовано',
                );
              }
              return tx.message.findUniqueOrThrow({
                where: { id: created.id },
                include: messageRelations,
              });
            });

      this.messagesGateway.emitMessageNew(channelId, message);
      return message;
    } catch (error) {
      if (
        !clientMessageId ||
        !(error instanceof Prisma.PrismaClientKnownRequestError) ||
        error.code !== 'P2002'
      ) {
        throw error;
      }
      // При двух одновременных POST уникальный индекс пропускает только один.
      // Проигравший запрос возвращает ту же запись без повторного события.
      const existing = await returnExisting(clientMessageId);
      if (existing) return existing;
      throw error;
    }
  }

  async findByChannel(
    channelId: string,
    userId: string,
    options?: { limit?: number; before?: string; after?: string },
  ) {
    const channel = await this.getChannelForUser(channelId, userId);

    const isOwner = this.isServerOwner(channel, userId);
    const permissions = this.getPermissions(channel.permissions);

    if (!isOwner && !permissions.canView) {
      throw new ForbiddenException('У вас нет доступа к этому каналу');
    }

    if (channel.type !== ChannelType.TEXT) {
      throw new BadRequestException(
        'История сообщений есть только у текстовых каналов',
      );
    }

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
      const cursorMessage = await this.prisma.message.findUnique({
        where: { id: options.before },
        select: { createdAt: true, channelId: true },
      });

      if (!cursorMessage || cursorMessage.channelId !== channelId) {
        throw new BadRequestException('Некорректный курсор пагинации');
      }

      // Составной курсор (createdAt, id): защищает от потери сообщений
      // с одинаковым createdAt на границе страницы.
      cursorFilter = {
        OR: [
          { createdAt: { lt: cursorMessage.createdAt } },
          { createdAt: cursorMessage.createdAt, id: { lt: options.before } },
        ],
      };
    } else if (options?.after) {
      const cursorMessage = await this.prisma.message.findUnique({
        where: { id: options.after },
        select: { createdAt: true, channelId: true },
      });

      if (!cursorMessage || cursorMessage.channelId !== channelId) {
        throw new BadRequestException('Некорректный курсор пагинации');
      }

      // Составной курсор (createdAt, id) для догрузки сообщений, пропущенных
      // во время обрыва realtime-соединения.
      cursorFilter = {
        OR: [
          { createdAt: { gt: cursorMessage.createdAt } },
          { createdAt: cursorMessage.createdAt, id: { gt: options.after } },
        ],
      };
    }

    const messages = await this.prisma.message.findMany({
      where: {
        channelId,
        deletedAt: null,
        ...cursorFilter,
      },
      orderBy: options?.after
        ? [{ createdAt: 'asc' }, { id: 'asc' }]
        : [{ createdAt: 'desc' }, { id: 'desc' }],
      take: limit,
      include: messageRelations,
    });

    if (options?.after) {
      // Для курсора "вперёд" Prisma уже отдаёт страницу в хронологическом
      // порядке (от старых к новым), реверс не нужен.
      return messages;
    }

    // Отдаём страницу в хронологическом порядке (от старых к новым), как и раньше.
    return messages.reverse();
  }

  async update(messageId: string, userId: string, dto: UpdateMessageDto) {
    const message = await this.prisma.message.findUnique({
      where: {
        id: messageId,
      },
      include: {
        channel: {
          include: {
            server: true,
          },
        },
      },
    });

    if (!message || message.deletedAt) {
      throw new NotFoundException('Сообщение не найдено');
    }

    if (message.authorId !== userId) {
      throw new ForbiddenException('Можно редактировать только свои сообщения');
    }

    const member = await this.prisma.serverMember.findUnique({
      where: {
        serverId_userId: {
          serverId: message.channel.serverId,
          userId,
        },
      },
    });

    if (!member) {
      throw new ForbiddenException('Вы не состоите на этом сервере');
    }

    const permissions = this.getPermissions(message.channel.permissions);
    const isOwner = message.channel.server.ownerId === userId;

    if (!isOwner && !permissions.canView) {
      throw new ForbiddenException('У вас нет доступа к этому каналу');
    }

    if (!isOwner && !permissions.canSendMessages) {
      throw new ForbiddenException(
        'В этом канале нельзя редактировать сообщения',
      );
    }

    const updatedMessage = await this.prisma.message.update({
      where: {
        id: messageId,
      },
      data: {
        content: dto.content,
      },
      include: messageRelations,
    });

    this.messagesGateway.emitMessageUpdate(
      updatedMessage.channelId,
      updatedMessage,
    );

    return updatedMessage;
  }

  async remove(messageId: string, userId: string) {
    const message = await this.prisma.message.findUnique({
      where: {
        id: messageId,
      },
      include: {
        channel: {
          include: {
            server: true,
          },
        },
      },
    });

    if (!message || message.deletedAt) {
      throw new NotFoundException('Сообщение не найдено');
    }

    if (message.authorId !== userId) {
      throw new ForbiddenException('Можно удалять только свои сообщения');
    }

    const member = await this.prisma.serverMember.findUnique({
      where: {
        serverId_userId: {
          serverId: message.channel.serverId,
          userId,
        },
      },
    });

    if (!member) {
      throw new ForbiddenException('Вы не состоите на этом сервере');
    }

    const permissions = this.getPermissions(message.channel.permissions);
    const isOwner = message.channel.server.ownerId === userId;

    if (!isOwner && !permissions.canView) {
      throw new ForbiddenException('У вас нет доступа к этому каналу');
    }

    const deletedMessage = await this.prisma.$transaction(async (tx) => {
      const deleted = await tx.message.update({
        where: { id: messageId },
        data: { deletedAt: new Date() },
      });
      // Database trigger places storage keys in the durable cleanup queue.
      await tx.attachment.deleteMany({ where: { messageId } });
      return deleted;
    });

    this.messagesGateway.emitMessageDelete(deletedMessage.channelId, {
      id: deletedMessage.id,
      channelId: deletedMessage.channelId,
    });

    return deletedMessage;
  }
}
