import {
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { PermissionsService } from '../permissions/permissions.service';
import { SERVER_PERMISSION_KEYS } from '../permissions/permission-keys';
import { RolePayload, ServersGateway } from '../servers/servers.gateway';
import { CreateRoleDto } from './dto/create-role.dto';
import { UpdateRoleDto } from './dto/update-role.dto';

const MANAGE_ROLES_MESSAGE = 'Недостаточно прав для управления ролями';

@Injectable()
export class RolesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly permissionsService: PermissionsService,
    private readonly serversGateway: ServersGateway,
  ) {}

  private toRolePayload(role: {
    id: string;
    name: string;
    color: string | null;
    position: number;
  }): RolePayload {
    return {
      id: role.id,
      name: role.name,
      color: role.color,
      position: role.position,
    };
  }

  private extractPermissions(
    dto: Partial<Record<(typeof SERVER_PERMISSION_KEYS)[number], boolean>>,
  ): Record<string, boolean> {
    const permissions: Record<string, boolean> = {};

    for (const key of SERVER_PERMISSION_KEYS) {
      if (dto[key] !== undefined) {
        permissions[key] = dto[key] as boolean;
      }
    }

    return permissions;
  }

  private parsePermissions(raw: unknown): Record<string, boolean> {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      return {};
    }

    return raw as Record<string, boolean>;
  }

  private async getRoleOrThrow(roleId: string) {
    const role = await this.prisma.role.findUnique({ where: { id: roleId } });

    if (!role) {
      throw new NotFoundException('Роль не найдена');
    }

    return role;
  }

  private async getMemberOrThrow(serverId: string, memberId: string) {
    const member = await this.prisma.serverMember.findUnique({
      where: { id: memberId },
      include: { roles: true },
    });

    if (!member || member.serverId !== serverId) {
      throw new NotFoundException('Участник сервера не найден');
    }

    return member;
  }

  async createRole(userId: string, serverId: string, dto: CreateRoleDto) {
    await this.permissionsService.assertPermission(
      userId,
      serverId,
      'manageRoles',
      MANAGE_ROLES_MESSAGE,
    );

    const existing = await this.prisma.role.findUnique({
      where: { serverId_name: { serverId, name: dto.name } },
    });

    if (existing) {
      throw new ConflictException('Роль с таким названием уже существует');
    }

    const rolesCount = await this.prisma.role.count({ where: { serverId } });

    const role = await this.prisma.role.create({
      data: {
        serverId,
        name: dto.name,
        color: dto.color,
        position: rolesCount,
        permissions: this.extractPermissions(dto),
      },
    });

    this.serversGateway.emitRoleNew({
      serverId,
      role: this.toRolePayload(role),
    });

    return role;
  }

  async getServerRoles(userId: string, serverId: string) {
    await this.permissionsService.getServerOrThrow(serverId);

    const isOwner = await this.permissionsService.isOwner(userId, serverId);

    if (!isOwner) {
      const member = await this.prisma.serverMember.findUnique({
        where: { serverId_userId: { serverId, userId } },
      });

      if (!member) {
        throw new ForbiddenException('У вас нет доступа к этому серверу');
      }
    }

    return this.prisma.role.findMany({
      where: { serverId },
      orderBy: { position: 'asc' },
    });
  }

  async updateRole(userId: string, roleId: string, dto: UpdateRoleDto) {
    const role = await this.getRoleOrThrow(roleId);

    await this.permissionsService.assertPermission(
      userId,
      role.serverId,
      'manageRoles',
      MANAGE_ROLES_MESSAGE,
    );

    if (dto.name && dto.name !== role.name) {
      const existing = await this.prisma.role.findUnique({
        where: { serverId_name: { serverId: role.serverId, name: dto.name } },
      });

      if (existing) {
        throw new ConflictException('Роль с таким названием уже существует');
      }
    }

    const updatedPermissions = {
      ...this.parsePermissions(role.permissions),
      ...this.extractPermissions(dto),
    };

    const updatedRole = await this.prisma.role.update({
      where: { id: roleId },
      data: {
        name: dto.name,
        color: dto.color,
        position: dto.position,
        permissions: updatedPermissions,
      },
    });

    this.serversGateway.emitRoleUpdate({
      serverId: role.serverId,
      role: this.toRolePayload(updatedRole),
    });

    return updatedRole;
  }

  async deleteRole(userId: string, roleId: string) {
    const role = await this.getRoleOrThrow(roleId);

    await this.permissionsService.assertPermission(
      userId,
      role.serverId,
      'manageRoles',
      MANAGE_ROLES_MESSAGE,
    );

    await this.prisma.role.delete({ where: { id: roleId } });

    this.serversGateway.emitRoleDelete({
      serverId: role.serverId,
      roleId: role.id,
    });

    return { message: 'Роль удалена' };
  }

  async assignRole(
    userId: string,
    serverId: string,
    memberId: string,
    roleId: string,
  ) {
    await this.permissionsService.assertPermission(
      userId,
      serverId,
      'manageRoles',
      MANAGE_ROLES_MESSAGE,
    );

    const member = await this.getMemberOrThrow(serverId, memberId);
    const role = await this.getRoleOrThrow(roleId);

    if (role.serverId !== serverId) {
      throw new NotFoundException('Роль не найдена на этом сервере');
    }

    if (member.roles.some((existingRole) => existingRole.id === roleId)) {
      throw new ConflictException('Роль уже назначена этому участнику');
    }

    try {
      await this.prisma.role.update({
        where: { id: roleId },
        data: { members: { connect: { id: memberId } } },
      });
    } catch (error) {
      // Параллельный вызов мог назначить роль между проверкой выше и connect —
      // уникальный индекс join-таблицы превращает гонку в P2002, а не в дубль.
      if (
        error instanceof Prisma.PrismaClientKnownRequestError &&
        error.code === 'P2002'
      ) {
        throw new ConflictException('Роль уже назначена этому участнику');
      }

      throw error;
    }

    await this.emitMemberRolesUpdate(serverId, memberId, member.userId);

    return { message: 'Роль назначена' };
  }

  async unassignRole(
    userId: string,
    serverId: string,
    memberId: string,
    roleId: string,
  ) {
    await this.permissionsService.assertPermission(
      userId,
      serverId,
      'manageRoles',
      MANAGE_ROLES_MESSAGE,
    );

    const member = await this.getMemberOrThrow(serverId, memberId);
    const role = await this.getRoleOrThrow(roleId);

    if (role.serverId !== serverId) {
      throw new NotFoundException('Роль не найдена на этом сервере');
    }

    if (!member.roles.some((existingRole) => existingRole.id === roleId)) {
      throw new NotFoundException('Роль не назначена этому участнику');
    }

    try {
      await this.prisma.role.update({
        where: { id: roleId },
        data: { members: { disconnect: { id: memberId } } },
      });
    } catch (error) {
      if (
        error instanceof Prisma.PrismaClientKnownRequestError &&
        (error.code === 'P2017' || error.code === 'P2025')
      ) {
        throw new NotFoundException('Р РѕР»СЊ РЅРµ РЅР°Р·РЅР°С‡РµРЅР° СЌС‚РѕРјСѓ СѓС‡Р°СЃС‚РЅРёРєСѓ');
      }

      throw error;
    }

    await this.emitMemberRolesUpdate(serverId, memberId, member.userId);

    return { message: 'Роль снята' };
  }

  private async emitMemberRolesUpdate(
    serverId: string,
    memberId: string,
    userId: string,
  ) {
    const member = await this.prisma.serverMember.findUnique({
      where: { id: memberId },
      include: { roles: true },
    });

    this.serversGateway.emitMemberRolesUpdate({
      serverId,
      memberId,
      userId,
      roles: (member?.roles ?? []).map((role) => this.toRolePayload(role)),
    });
  }
}
