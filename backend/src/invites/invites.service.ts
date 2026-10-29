import { BadRequestException, ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { randomBytes } from 'crypto';
import { PrismaService } from '../prisma/prisma.service';
import { PermissionsService } from '../permissions/permissions.service';
import { ServersGateway } from '../servers/servers.gateway';
import { CreateInviteDto } from './dto/create-invite.dto';

@Injectable()
export class InvitesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly serversGateway: ServersGateway,
    private readonly permissionsService: PermissionsService,
  ) {}

  // Владелец сервера всегда проходит эту проверку; для остальных участников
  // решает эффективное право manageInvites (пока роли никому не назначены,
  // поведение не отличается от прежней точечной проверки ownerId).
  private async getServerOwnerOrThrow(userId: string, serverId: string) {
    return this.permissionsService.assertPermission(
      userId,
      serverId,
      'manageInvites',
      'Только владелец сервера может создавать приглашения',
    );
  }

  private async getUsableInviteOrThrow(code: string) {
    const invite = await this.prisma.invite.findUnique({
      where: {
        code,
      },
      include: {
        server: {
          select: {
            id: true,
            name: true,
            iconUrl: true,
            ownerId: true,
            createdAt: true,
            updatedAt: true,
          },
        },
      },
    });

    if (!invite) {
      throw new NotFoundException('Приглашение не найдено');
    }

    if (invite.expiresAt && invite.expiresAt <= new Date()) {
      throw new BadRequestException('Срок действия приглашения истёк');
    }

    if (invite.maxUses !== null && invite.currentUses >= invite.maxUses) {
      throw new BadRequestException('Лимит использований приглашения исчерпан');
    }

    return invite;
  }

  private async generateInviteCode() {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const code = randomBytes(8).toString('base64url');
      const existingInvite = await this.prisma.invite.findUnique({
        where: {
          code,
        },
      });

      if (!existingInvite) {
        return code;
      }
    }

    throw new BadRequestException('Не удалось создать код приглашения');
  }

  async createInvite(userId: string, serverId: string, dto: CreateInviteDto) {
    await this.getServerOwnerOrThrow(userId, serverId);

    const expiresAt = dto.expiresAt ? new Date(dto.expiresAt) : null;

    if (expiresAt && expiresAt <= new Date()) {
      throw new BadRequestException(
        'Срок действия приглашения должен быть в будущем',
      );
    }

    const code = await this.generateInviteCode();

    return this.prisma.invite.create({
      data: {
        serverId,
        code,
        createdBy: userId,
        expiresAt,
        maxUses: dto.maxUses ?? null,
      },
      include: {
        server: {
          select: {
            id: true,
            name: true,
            iconUrl: true,
            ownerId: true,
          },
        },
      },
    });
  }

  async getInvite(code: string) {
    const invite = await this.getUsableInviteOrThrow(code);

    return {
      id: invite.id,
      code: invite.code,
      expiresAt: invite.expiresAt,
      maxUses: invite.maxUses,
      currentUses: invite.currentUses,
      server: invite.server,
    };
  }

  async joinInvite(userId: string, code: string) {
    const invite = await this.getUsableInviteOrThrow(code);

    const ban = await this.prisma.serverBan.findUnique({
      where: {
        serverId_userId: {
          serverId: invite.serverId,
          userId,
        },
      },
    });

    if (ban) {
      throw new ForbiddenException('Вы забанены на этом сервере');
    }

    const existingMember = await this.prisma.serverMember.findUnique({
      where: {
        serverId_userId: {
          serverId: invite.serverId,
          userId,
        },
      },
    });

    if (existingMember) {
      return invite.server;
    }

    try {
      const member = await this.prisma.$transaction(async (tx) => {
        // Атомарная условная проверка лимита: UPDATE ... WHERE currentUses < maxUses
        // берёт row-lock на строку приглашения, поэтому параллельные join-транзакции
        // сериализуются на этом условии и не могут вдвоём "пройти" один и тот же лимит.
        if (invite.maxUses !== null) {
          const incremented = await tx.invite.updateMany({
            where: {
              id: invite.id,
              currentUses: { lt: invite.maxUses },
            },
            data: {
              currentUses: { increment: 1 },
            },
          });

          if (incremented.count === 0) {
            throw new BadRequestException('Лимит использований приглашения исчерпан');
          }
        } else {
          await tx.invite.update({
            where: { id: invite.id },
            data: { currentUses: { increment: 1 } },
          });
        }

        return tx.serverMember.create({
          data: {
            serverId: invite.serverId,
            userId,
          },
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
        });
      });

      this.serversGateway.emitMemberJoin(member);

      return invite.server;
    } catch (error) {
      if (
        error instanceof Prisma.PrismaClientKnownRequestError &&
        error.code === 'P2002'
      ) {
        // Параллельный join того же нового пользователя уже создал ServerMember
        // в своей транзакции первым; инкремент currentUses этой транзакции был
        // откатён вместе с ней, так что лишнее использование инвайта не тратится.
        return invite.server;
      }
      throw error;
    }
  }
}
