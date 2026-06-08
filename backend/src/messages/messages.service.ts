import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { ChannelType } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { CreateMessageDto } from './dto/create-message.dto';
import { MessagesGateway } from './messages.gateway';
import { UpdateMessageDto } from './dto/update-message.dto';

type ChannelPermissions = {
  canView?: boolean;
  canSendMessages?: boolean;
  canConnect?: boolean;
};

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

    const message = await this.prisma.message.create({
      data: {
        channelId,
        authorId: userId,
        content: dto.content,
      },
      include: {
        author: {
          select: {
            id: true,
            username: true,
            email: true,
            avatarUrl: true,
            status: true,
          },
        },
      },
    });

    this.messagesGateway.emitMessageNew(channelId, message);

    return message;
  }

  async findByChannel(channelId: string, userId: string) {
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

    return this.prisma.message.findMany({
      where: {
        channelId,
        deletedAt: null,
      },
      orderBy: {
        createdAt: 'asc',
      },
      include: {
        author: {
          select: {
            id: true,
            username: true,
            email: true,
            avatarUrl: true,
            status: true,
          },
        },
      },
    });
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
      include: {
        author: {
          select: {
            id: true,
            username: true,
            email: true,
            avatarUrl: true,
            status: true,
          },
        },
      },
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

    const permissions = this.getPermissions(message.channel.permissions);
    const isOwner = message.channel.server.ownerId === userId;

    if (!isOwner && !permissions.canView) {
      throw new ForbiddenException('У вас нет доступа к этому каналу');
    }

    const deletedMessage = await this.prisma.message.update({
      where: {
        id: messageId,
      },
      data: {
        deletedAt: new Date(),
      },
    });

    this.messagesGateway.emitMessageDelete(deletedMessage.channelId, {
      id: deletedMessage.id,
      channelId: deletedMessage.channelId,
    });

    return deletedMessage;
  }
}
