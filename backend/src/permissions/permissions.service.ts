import { ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import { Server } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  SERVER_PERMISSION_KEYS,
  ServerPermissionKey,
  ServerPermissionSet,
} from './permission-keys';

function emptyPermissionSet(): ServerPermissionSet {
  return SERVER_PERMISSION_KEYS.reduce((set, key) => {
    set[key] = false;
    return set;
  }, {} as ServerPermissionSet);
}

function allPermissionSet(): ServerPermissionSet {
  return SERVER_PERMISSION_KEYS.reduce((set, key) => {
    set[key] = true;
    return set;
  }, {} as ServerPermissionSet);
}

/**
 * Единая точка расчёта эффективных прав участника на сервере.
 *
 * Владелец сервера всегда имеет полный доступ, независимо от назначенных
 * ролей. Остальные права участника — это объединение (union) permissions
 * всех назначенных ему ролей: если хотя бы одна роль разрешает действие,
 * оно разрешено.
 */
@Injectable()
export class PermissionsService {
  constructor(private readonly prisma: PrismaService) {}

  async getServerOrThrow(serverId: string): Promise<Server> {
    const server = await this.prisma.server.findUnique({
      where: { id: serverId },
    });

    if (!server) {
      throw new NotFoundException('Сервер не найден');
    }

    return server;
  }

  async isOwner(userId: string, serverId: string): Promise<boolean> {
    const server = await this.getServerOrThrow(serverId);

    return server.ownerId === userId;
  }

  async getEffectivePermissions(
    userId: string,
    serverId: string,
  ): Promise<ServerPermissionSet> {
    const server = await this.getServerOrThrow(serverId);

    if (server.ownerId === userId) {
      return allPermissionSet();
    }

    const member = await this.prisma.serverMember.findUnique({
      where: { serverId_userId: { serverId, userId } },
      include: { roles: true },
    });

    if (!member) {
      return emptyPermissionSet();
    }

    return this.mergeRolePermissions(member.roles);
  }

  /**
   * Разрешает действие владельцу сервера всегда, а остальным участникам —
   * только если хотя бы одна из назначенных ролей содержит `key`. Бросает
   * ForbiddenException с переданным сообщением, если доступа нет.
   *
   * Возвращает загруженный сервер, чтобы вызывающий код не делал повторный
   * запрос (многие точечные проверки ownerId использовали загруженный
   * сервер и дальше по коду, например чтобы сравнить с ownerId цели).
   */
  async assertPermission(
    userId: string,
    serverId: string,
    key: ServerPermissionKey,
    message: string,
  ): Promise<Server> {
    const server = await this.getServerOrThrow(serverId);

    if (server.ownerId === userId) {
      return server;
    }

    const member = await this.prisma.serverMember.findUnique({
      where: { serverId_userId: { serverId, userId } },
      include: { roles: true },
    });

    const permissions = member
      ? this.mergeRolePermissions(member.roles)
      : emptyPermissionSet();

    if (!permissions[key]) {
      throw new ForbiddenException(message);
    }

    return server;
  }

  private mergeRolePermissions(
    roles: { permissions: unknown }[],
  ): ServerPermissionSet {
    const merged = emptyPermissionSet();

    for (const role of roles) {
      const rolePermissions = this.parseRolePermissions(role.permissions);

      for (const key of SERVER_PERMISSION_KEYS) {
        if (rolePermissions[key]) {
          merged[key] = true;
        }
      }
    }

    return merged;
  }

  private parseRolePermissions(raw: unknown): Partial<ServerPermissionSet> {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      return {};
    }

    return raw as Partial<ServerPermissionSet>;
  }
}
