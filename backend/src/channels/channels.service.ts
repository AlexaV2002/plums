import {
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { CreateChannelDto } from './dto/create-channel.dto';
import { UpdateChannelPermissionsDto } from './dto/update-channel-permissions.dto';
import { UpdateChannelDto } from './dto/update-channel.dto';
import { ChannelsGateway } from './channels.gateway';

type ChannelPermissions = {
  canView?: boolean;
  canSendMessages?: boolean;
  canConnect?: boolean;
};

@Injectable()
export class ChannelsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly channelsGateway: ChannelsGateway,
  ) {}

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

  private getPermissions(rawPermissions: unknown): Required<ChannelPermissions> {
    if (
      !rawPermissions ||
      typeof rawPermissions !== 'object' ||
      Array.isArray(rawPermissions)
    ) {
      return {
        canView: true,
        canSendMessages: true,
        canConnect: true,
      };
    }

    const permissions = rawPermissions as ChannelPermissions;

    return {
      canView: permissions.canView ?? true,
      canSendMessages: permissions.canSendMessages ?? true,
      canConnect: permissions.canConnect ?? true,
    };
  }

  async createChannel(userId: string, serverId: string, dto: CreateChannelDto) {
    await this.checkServerOwner(userId, serverId);

    const channelsCount = await this.prisma.channel.count({
      where: {
        serverId,
      },
    });

    const channel = await this.prisma.channel.create({
      data: {
        serverId,
        name: dto.name,
        type: dto.type ?? 'TEXT',
        position: channelsCount,
      },
    });

    this.channelsGateway.emitChannelNew(serverId, channel);

    return channel;
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
      const permissions = this.getPermissions(channel.permissions);

      return permissions.canView;
    });
  }

  async updateChannel(
    userId: string,
    channelId: string,
    dto: UpdateChannelDto,
  ) {
    const channel = await this.getChannelOrThrow(channelId);

    await this.checkServerOwner(userId, channel.serverId);

    const updatedChannel = await this.prisma.channel.update({
      where: {
        id: channelId,
      },
      data: {
        name: dto.name,
      },
    });

    this.channelsGateway.emitChannelUpdate(
      updatedChannel.serverId,
      updatedChannel,
    );

    return updatedChannel;
  }

  async deleteChannel(userId: string, channelId: string) {
    const channel = await this.getChannelOrThrow(channelId);

    await this.checkServerOwner(userId, channel.serverId);

    await this.prisma.channel.delete({
      where: {
        id: channelId,
      },
    });

    this.channelsGateway.emitChannelDelete(channel.serverId, {
      id: channel.id,
      serverId: channel.serverId,
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

    const currentPermissions = this.getPermissions(channel.permissions);

    const updatedChannel = await this.prisma.channel.update({
      where: {
        id: channelId,
      },
      data: {
        permissions: {
          ...currentPermissions,
          ...dto,
        },
      },
    });

    this.channelsGateway.emitChannelUpdate(
      updatedChannel.serverId,
      updatedChannel,
    );

    return updatedChannel;
  }
}
