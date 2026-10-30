import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
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

  private async getInviteOrThrow(code: string) {
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

    return invite;
  }

  private assertInviteAvailable(invite: {
    expiresAt: Date | null;
    maxUses: number | null;
    currentUses: number;
  }) {
    if (invite.expiresAt && invite.expiresAt <= new Date()) {
      throw new BadRequestException('Срок действия приглашения истёк');
    }

    if (invite.maxUses !== null && invite.currentUses >= invite.maxUses) {
      throw new BadRequestException('Лимит использований приглашения исчерпан');
    }
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
    const invite = await this.getInviteOrThrow(code);
    this.assertInviteAvailable(invite);

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
    const invite = await this.getInviteOrThrow(code);

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

    this.assertInviteAvailable(invite);

    try {
      const member = await this.prisma.$transaction(async (tx) => {
        // Сериализуем join и ban для одной пары (serverId, userId): лок берём
        // первым действием транзакции, чтобы конкурентный banServerMember не
        // мог "разминуться" с этим вступлением (см. тот же lock-key там).
        await tx.$queryRaw`SELECT 1 FROM pg_advisory_xact_lock(hashtextextended(${`${invite.serverId}:${userId}`}, 0))`;

        const freshBan = await tx.serverBan.findUnique({
          where: {
            serverId_userId: {
              serverId: invite.serverId,
              userId,
            },
          },
        });

        if (freshBan) {
          throw new ForbiddenException('Вы забанены на этом сервере');
        }

        // Второй конкурентный join того же пользователя не расходует инвайт.
        const freshMember = await tx.serverMember.findUnique({
          where: {
            serverId_userId: { serverId: invite.serverId, userId },
          },
        });
        if (freshMember) return null;

        // Берём row-lock до проверки срока и лимита. clock_timestamp() ниже
        // вычисляется уже после ожидания других использований приглашения.
        await tx.$queryRaw`SELECT "id" FROM "invites" WHERE "id" = ${invite.id} FOR UPDATE`;
        const incremented = await tx.$queryRaw<Array<{ id: string }>>`
          UPDATE "invites"
          SET "currentUses" = "currentUses" + 1
          WHERE "id" = ${invite.id}
            AND ("expiresAt" IS NULL OR "expiresAt" > clock_timestamp())
            AND ("maxUses" IS NULL OR "currentUses" < "maxUses")
          RETURNING "id"
        `;

        if (incremented.length === 0) {
          const current = await tx.invite.findUnique({
            where: { id: invite.id },
          });
          const isExpired =
            !current ||
            (current.expiresAt !== null && current.expiresAt <= new Date());

          if (isExpired) {
            throw new BadRequestException('Срок действия приглашения истёк');
          }
          throw new BadRequestException(
            'Лимит использований приглашения исчерпан',
          );
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
                avatarUrl: true,
                status: true,
                bio: true,
              },
            },
          },
        });
      });

      if (member) this.serversGateway.emitMemberJoin(member);

      return invite.server;
    } catch (error) {
      if (
        error instanceof Prisma.PrismaClientKnownRequestError &&
        error.code === 'P2002'
      ) {
        // Другая транзакция могла создать участника без нашего advisory lock.
        // Подтверждаем итоговое членство и отсутствие бана перед ответом.
        const [member, banAfterConflict] = await Promise.all([
          this.prisma.serverMember.findUnique({
            where: { serverId_userId: { serverId: invite.serverId, userId } },
          }),
          this.prisma.serverBan.findUnique({
            where: { serverId_userId: { serverId: invite.serverId, userId } },
          }),
        ]);
        if (member && !banAfterConflict) return invite.server;
      }
      throw error;
    }
  }
}
