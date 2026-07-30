import {
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { PermissionsService } from '../permissions/permissions.service';
import { ServerPermissionKey } from '../permissions/permission-keys';
import { BanMemberDto } from './dto/ban-member.dto';
import { CreateServerDto } from './dto/create-server.dto';
import { UpdateServerDto } from './dto/update-server.dto';
import { ServersGateway } from './servers.gateway';

@Injectable()
export class ServersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly serversGateway: ServersGateway,
    private readonly permissionsService: PermissionsService,
  ) {}

  private async getServerOrThrow(serverId: string) {
    return this.permissionsService.getServerOrThrow(serverId);
  }

  // Владелец сервера всегда проходит эту проверку. Пока участникам не
  // назначены роли с соответствующим правом, поведение для не-владельцев
  // не меняется — эффективные права такого участника пусты, как и раньше
  // при точечной проверке ownerId. Ключ права передаётся вызывающим кодом,
  // чтобы разные действия (управление сервером / участниками / банами)
  // впоследствии можно было разрешать разными ролями, а не только владельцу.
  private async getServerOwnerOrThrow(
    userId: string,
    serverId: string,
    key: ServerPermissionKey = 'manageServer',
  ) {
    return this.permissionsService.assertPermission(
      userId,
      serverId,
      key,
      'Только владелец сервера может управлять сервером',
    );
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
            roles: {
              select: {
                id: true,
                name: true,
                color: true,
                position: true,
              },
              orderBy: { position: 'asc' },
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
        roles: {
          select: {
            id: true,
            name: true,
            color: true,
            position: true,
          },
          orderBy: { position: 'asc' },
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

    this.serversGateway.emitMemberLeave({
      serverId,
      userId,
      memberId: member.id,
      reason: 'leave',
    });

    return {
      message: 'Вы вышли с сервера',
    };
  }

  async kickServerMember(userId: string, serverId: string, memberId: string) {
    const server = await this.getServerOwnerOrThrow(
      userId,
      serverId,
      'manageMembers',
    );

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

    this.serversGateway.emitMemberLeave({
      serverId,
      userId: member.userId,
      memberId: member.id,
      reason: 'kick',
    });

    return {
      message: 'Участник удалён с сервера',
    };
  }

  async banServerMember(
    userId: string,
    serverId: string,
    targetUserId: string,
    dto: BanMemberDto,
  ) {
    const server = await this.getServerOwnerOrThrow(
      userId,
      serverId,
      'manageBans',
    );

    if (targetUserId === server.ownerId) {
      throw new ForbiddenException('Нельзя забанить владельца сервера');
    }

    const existingBan = await this.prisma.serverBan.findUnique({
      where: {
        serverId_userId: {
          serverId,
          userId: targetUserId,
        },
      },
    });

    if (existingBan) {
      throw new ConflictException('Пользователь уже забанен на этом сервере');
    }

    const member = await this.prisma.serverMember.findUnique({
      where: {
        serverId_userId: {
          serverId,
          userId: targetUserId,
        },
      },
    });

    await this.prisma.$transaction([
      this.prisma.serverBan.create({
        data: {
          serverId,
          userId: targetUserId,
          bannedBy: userId,
          reason: dto.reason,
        },
      }),
      ...(member
        ? [
            this.prisma.serverMember.delete({
              where: { id: member.id },
            }),
          ]
        : []),
    ]);

    if (member) {
      this.serversGateway.emitMemberLeave({
        serverId,
        userId: targetUserId,
        memberId: member.id,
        reason: 'ban',
      });
    }

    return {
      message: 'Пользователь забанен на сервере',
    };
  }

  async unbanServerMember(
    userId: string,
    serverId: string,
    targetUserId: string,
  ) {
    await this.getServerOwnerOrThrow(userId, serverId, 'manageBans');

    const ban = await this.prisma.serverBan.findUnique({
      where: {
        serverId_userId: {
          serverId,
          userId: targetUserId,
        },
      },
    });

    if (!ban) {
      throw new NotFoundException('Пользователь не забанен на этом сервере');
    }

    await this.prisma.serverBan.delete({
      where: { id: ban.id },
    });

    return {
      message: 'Пользователь разбанен',
    };
  }

  async getServerBans(userId: string, serverId: string) {
    await this.getServerOwnerOrThrow(userId, serverId, 'manageBans');

    return this.prisma.serverBan.findMany({
      where: { serverId },
      orderBy: { createdAt: 'desc' },
      select: {
        id: true,
        serverId: true,
        userId: true,
        bannedBy: true,
        reason: true,
        createdAt: true,
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
}
