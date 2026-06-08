import { ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { CreateServerDto } from './dto/create-server.dto';
import { UpdateServerDto } from './dto/update-server.dto';

@Injectable()
export class ServersService {
  constructor(private readonly prisma: PrismaService) {}

  private async getServerOrThrow(serverId: string) {
    const server = await this.prisma.server.findUnique({
      where: {
        id: serverId,
      },
    });

    if (!server) {
      throw new NotFoundException('Сервер не найден');
    }

    return server;
  }

  private async getServerOwnerOrThrow(userId: string, serverId: string) {
    const server = await this.getServerOrThrow(serverId);

    if (server.ownerId !== userId) {
      throw new ForbiddenException(
        'Только владелец сервера может управлять сервером',
      );
    }

    return server;
  }

  private async getServerMemberOrThrow(userId: string, serverId: string) {
    const server = await this.getServerOrThrow(serverId);

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

    return { server, member };
  }

  async createServer(ownerId: string, dto: CreateServerDto) {
    return this.prisma.server.create({
      data: {
        name: dto.name,
        iconUrl: dto.iconUrl,
        ownerId,
        members: {
          create: {
            userId: ownerId,
          },
        },
      },
      include: {
        members: true,
      },
    });
  }

  async getMyServers(userId: string) {
    return this.prisma.server.findMany({
      where: {
        members: {
          some: {
            userId,
          },
        },
      },
      orderBy: {
        createdAt: 'asc',
      },
      select: {
        id: true,
        name: true,
        iconUrl: true,
        ownerId: true,
        createdAt: true,
        updatedAt: true,
      },
    });
  }

  async getServerById(userId: string, serverId: string) {
    const server = await this.prisma.server.findUnique({
      where: {
        id: serverId,
      },
      include: {
        members: {
          include: {
            user: {
              select: {
                id: true,
                username: true,
                email: true,
                avatarUrl: true,
                status: true,
                bio: true,
              },
            },
          },
        },
      },
    });

    if (!server) {
      throw new NotFoundException('Сервер не найден');
    }

    const isMember = server.members.some((member) => member.userId === userId);

    if (!isMember) {
      throw new ForbiddenException('У вас нет доступа к этому серверу');
    }

    return server;
  }

  async getServerMembers(userId: string, serverId: string) {
    await this.getServerMemberOrThrow(userId, serverId);

    return this.prisma.serverMember.findMany({
      where: {
        serverId,
      },
      orderBy: {
        joinedAt: 'asc',
      },
      select: {
        id: true,
        serverId: true,
        userId: true,
        joinedAt: true,
        user: {
          select: {
            id: true,
            username: true,
            email: true,
            avatarUrl: true,
            status: true,
            bio: true,
          },
        },
      },
    });
  }

  async updateServer(userId: string, serverId: string, dto: UpdateServerDto) {
    await this.getServerOwnerOrThrow(userId, serverId);

    return this.prisma.server.update({
      where: {
        id: serverId,
      },
      data: {
        name: dto.name,
        iconUrl: dto.iconUrl,
      },
      select: {
        id: true,
        name: true,
        iconUrl: true,
        ownerId: true,
        createdAt: true,
        updatedAt: true,
      },
    });
  }

  async deleteServer(userId: string, serverId: string) {
    await this.getServerOwnerOrThrow(userId, serverId);

    await this.prisma.server.delete({
      where: {
        id: serverId,
      },
    });

    return {
      message: 'Сервер удалён',
    };
  }

  async leaveServer(userId: string, serverId: string) {
    const { server, member } = await this.getServerMemberOrThrow(
      userId,
      serverId,
    );

    if (server.ownerId === userId) {
      throw new ForbiddenException(
        'Владелец не может выйти из своего сервера. Удалите сервер или передайте владение.',
      );
    }

    await this.prisma.serverMember.delete({
      where: {
        id: member.id,
      },
    });

    return {
      message: 'Вы вышли с сервера',
    };
  }

  async kickServerMember(userId: string, serverId: string, memberId: string) {
    const server = await this.getServerOwnerOrThrow(userId, serverId);

    const member = await this.prisma.serverMember.findUnique({
      where: {
        id: memberId,
      },
    });

    if (!member || member.serverId !== serverId) {
      throw new NotFoundException('Участник сервера не найден');
    }

    if (member.userId === server.ownerId) {
      throw new ForbiddenException('Нельзя удалить владельца сервера');
    }

    await this.prisma.serverMember.delete({
      where: {
        id: memberId,
      },
    });

    return {
      message: 'Участник удалён с сервера',
    };
  }

}
