import {
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { CreateChannelDto } from './dto/create-channel.dto';
import { UpdateChannelPermissionsDto } from './dto/update-channel-permissions.dto';
import { UpdateChannelDto } from './dto/update-channel.dto';

@Injectable()
export class ChannelsService {
  constructor(private readonly prisma: PrismaService) {}

  private async checkServerAccess(userId: string, serverId: string) {
    const member = await this.prisma.serverMember.findUnique({
      where: {
        serverId_userId: {
          serverId,
          userId,
        },
      },
    });

    if (!member) {
      throw new ForbiddenException('У вас нет доступа к этому серверу');
    }

    return member;
  }

  private async checkServerOwner(userId: string, serverId: string) {
    const server = await this.prisma.server.findUnique({
      where: {
        id: serverId,
      },
    });

    if (!server) {
      throw new NotFoundException('Сервер не найден');
    }

    if (server.ownerId !== userId) {
      throw new ForbiddenException(
        'Только владелец сервера может управлять каналами',
      );
    }

    return server;
  }

  private async getChannelOrThrow(channelId: string) {
    const channel = await this.prisma.channel.findUnique({
      where: {
        id: channelId,
      },
    });

    if (!channel) {
      throw new NotFoundException('Канал не найден');
    }

    return channel;
  }

  private getCanView(rawPermissions: unknown) {
    if (
      !rawPermissions ||
      typeof rawPermissions !== 'object' ||
      Array.isArray(rawPermissions)
    ) {
      return true;
    }

    const permissions = rawPermissions as {
      canView?: boolean;
    };

    return permissions.canView ?? true;
  }

  async createChannel(userId: string, serverId: string, dto: CreateChannelDto) {
    await this.checkServerOwner(userId, serverId);

    const channelsCount = await this.prisma.channel.count({
      where: {
        serverId,
      },
    });

    return this.prisma.channel.create({
      data: {
        serverId,
        name: dto.name,
        type: dto.type ?? 'TEXT',
        position: channelsCount,
      },
    });
  }

  async getServerChannels(userId: string, serverId: string) {
    await this.checkServerAccess(userId, serverId);

    const server = await this.prisma.server.findUnique({
      where: {
        id: serverId,
      },
    });

    if (!server) {
      throw new NotFoundException('Сервер не найден');
    }

    const channels = await this.prisma.channel.findMany({
      where: {
        serverId,
      },
      orderBy: {
        position: 'asc',
      },
    });

    if (server.ownerId === userId) {
      return channels;
    }

    return channels.filter((channel) => {
      return this.getCanView(channel.permissions);
    });
  }

  async updateChannel(
    userId: string,
    channelId: string,
    dto: UpdateChannelDto,
  ) {
    const channel = await this.getChannelOrThrow(channelId);

    await this.checkServerOwner(userId, channel.serverId);

    return this.prisma.channel.update({
      where: {
        id: channelId,
      },
      data: {
        name: dto.name,
      },
    });
  }

  async deleteChannel(userId: string, channelId: string) {
    const channel = await this.getChannelOrThrow(channelId);

    await this.checkServerOwner(userId, channel.serverId);

    await this.prisma.channel.delete({
      where: {
        id: channelId,
      },
    });

    return {
      message: 'Канал удалён',
    };
  }

  async updateChannelPermissions(
    userId: string,
    channelId: string,
    dto: UpdateChannelPermissionsDto,
  ) {
    const channel = await this.getChannelOrThrow(channelId);

    await this.checkServerOwner(userId, channel.serverId);

    return this.prisma.channel.update({
      where: {
        id: channelId,
      },
      data: {
        permissions: {
          canView: dto.canView ?? true,
          canSendMessages: dto.canSendMessages ?? true,
          canConnect: dto.canConnect ?? true,
        },
      },
    });
  }
}