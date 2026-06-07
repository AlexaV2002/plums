import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { randomBytes } from 'crypto';
import { PrismaService } from '../prisma/prisma.service';
import { CreateInviteDto } from './dto/create-invite.dto';

@Injectable()
export class InvitesService {
  constructor(private readonly prisma: PrismaService) {}

  private async getServerOwnerOrThrow(userId: string, serverId: string) {
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
        'Только владелец сервера может создавать приглашения',
      );
    }

    return server;
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

    await this.prisma.$transaction([
      this.prisma.serverMember.create({
        data: {
          serverId: invite.serverId,
          userId,
        },
      }),
      this.prisma.invite.update({
        where: {
          id: invite.id,
        },
        data: {
          currentUses: {
            increment: 1,
          },
        },
      }),
    ]);

    return invite.server;
  }
}
