import { ConflictException, ForbiddenException, NotFoundException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { Prisma } from '@prisma/client';
import { PermissionsService } from '../permissions/permissions.service';
import { PrismaService } from '../prisma/prisma.service';
import { ServersGateway } from '../servers/servers.gateway';
import { RolesService } from './roles.service';

describe('RolesService', () => {
  let service: RolesService;
  let prisma: {
    role: {
      findUnique: jest.Mock;
      findMany: jest.Mock;
      count: jest.Mock;
      create: jest.Mock;
      update: jest.Mock;
      delete: jest.Mock;
    };
    serverMember: { findUnique: jest.Mock };
  };
  let permissionsService: {
    assertPermission: jest.Mock;
    getServerOrThrow: jest.Mock;
    isOwner: jest.Mock;
  };
  let serversGateway: {
    emitRoleNew: jest.Mock;
    emitRoleUpdate: jest.Mock;
    emitRoleDelete: jest.Mock;
    emitMemberRolesUpdate: jest.Mock;
  };

  const serverId = 'server-1';
  const userId = 'owner-1';
  const roleId = 'role-1';
  const memberId = 'member-1';

  beforeEach(async () => {
    prisma = {
      role: {
        findUnique: jest.fn(),
        findMany: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
      serverMember: { findUnique: jest.fn() },
    };

    permissionsService = {
      assertPermission: jest.fn().mockResolvedValue({ id: serverId, ownerId: userId }),
      getServerOrThrow: jest.fn().mockResolvedValue({ id: serverId, ownerId: userId }),
      isOwner: jest.fn().mockResolvedValue(true),
    };

    serversGateway = {
      emitRoleNew: jest.fn(),
      emitRoleUpdate: jest.fn(),
      emitRoleDelete: jest.fn(),
      emitMemberRolesUpdate: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        RolesService,
        { provide: PrismaService, useValue: prisma },
        { provide: PermissionsService, useValue: permissionsService },
        { provide: ServersGateway, useValue: serversGateway },
      ],
    }).compile();

    service = module.get<RolesService>(RolesService);
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('createRole', () => {
    it('requires the manageRoles permission', async () => {
      prisma.role.findUnique.mockResolvedValue(null);
      prisma.role.count.mockResolvedValue(0);
      prisma.role.create.mockResolvedValue({ id: roleId });

      await service.createRole(userId, serverId, { name: 'Moderator' });

      expect(permissionsService.assertPermission).toHaveBeenCalledWith(
        userId,
        serverId,
        'manageRoles',
        expect.any(String),
      );
    });

    it('rejects a duplicate role name on the same server', async () => {
      prisma.role.findUnique.mockResolvedValue({ id: 'existing-role' });

      await expect(
        service.createRole(userId, serverId, { name: 'Moderator' }),
      ).rejects.toThrow(ConflictException);
    });

    it('propagates ForbiddenException from PermissionsService when access is denied', async () => {
      permissionsService.assertPermission.mockRejectedValue(
        new ForbiddenException('Недостаточно прав для управления ролями'),
      );

      await expect(
        service.createRole('stranger', serverId, { name: 'Moderator' }),
      ).rejects.toThrow(ForbiddenException);
    });

    it('only persists explicitly provided permission flags', async () => {
      prisma.role.findUnique.mockResolvedValue(null);
      prisma.role.count.mockResolvedValue(2);
      prisma.role.create.mockResolvedValue({ id: roleId });

      await service.createRole(userId, serverId, {
        name: 'Moderator',
        manageBans: true,
      });

      expect(prisma.role.create).toHaveBeenCalledWith({
        data: {
          serverId,
          name: 'Moderator',
          color: undefined,
          position: 2,
          permissions: { manageBans: true },
        },
      });
    });

    it('emits role:new only after the role is persisted', async () => {
      prisma.role.findUnique.mockResolvedValue(null);
      prisma.role.count.mockResolvedValue(0);
      prisma.role.create.mockResolvedValue({
        id: roleId,
        name: 'Moderator',
        color: '#fff',
        position: 0,
      });

      await service.createRole(userId, serverId, { name: 'Moderator' });

      expect(serversGateway.emitRoleNew).toHaveBeenCalledWith({
        serverId,
        role: { id: roleId, name: 'Moderator', color: '#fff', position: 0 },
      });
    });

    it('does not emit role:new when creation fails', async () => {
      prisma.role.findUnique.mockResolvedValue({ id: 'existing-role' });

      await expect(
        service.createRole(userId, serverId, { name: 'Moderator' }),
      ).rejects.toThrow(ConflictException);

      expect(serversGateway.emitRoleNew).not.toHaveBeenCalled();
    });
  });

  describe('getServerRoles', () => {
    it('allows a plain member (not just the owner) to list roles', async () => {
      permissionsService.isOwner.mockResolvedValue(false);
      prisma.serverMember.findUnique.mockResolvedValue({ id: memberId });
      prisma.role.findMany.mockResolvedValue([]);

      await expect(
        service.getServerRoles('some-member', serverId),
      ).resolves.toEqual([]);
    });

    it('rejects a user who is neither owner nor member', async () => {
      permissionsService.isOwner.mockResolvedValue(false);
      prisma.serverMember.findUnique.mockResolvedValue(null);

      await expect(
        service.getServerRoles('stranger', serverId),
      ).rejects.toThrow(ForbiddenException);
    });
  });

  describe('assignRole / unassignRole', () => {
    it('assigns a role to a member who does not have it yet', async () => {
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        serverId,
        userId: 'target-user',
        roles: [],
      });
      prisma.role.findUnique.mockResolvedValue({ id: roleId, serverId });
      prisma.role.update.mockResolvedValue({ id: roleId });

      await service.assignRole(userId, serverId, memberId, roleId);

      expect(prisma.role.update).toHaveBeenCalledWith({
        where: { id: roleId },
        data: { members: { connect: { id: memberId } } },
      });
      expect(serversGateway.emitMemberRolesUpdate).toHaveBeenCalledWith({
        serverId,
        memberId,
        userId: 'target-user',
        roles: [],
      });
    });

    it('treats a concurrent duplicate connect (P2002) as already-assigned instead of crashing', async () => {
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        serverId,
        userId: 'target-user',
        roles: [],
      });
      prisma.role.findUnique.mockResolvedValue({ id: roleId, serverId });
      prisma.role.update.mockRejectedValue(
        new Prisma.PrismaClientKnownRequestError('Unique constraint failed', {
          code: 'P2002',
          clientVersion: 'test',
        }),
      );

      await expect(
        service.assignRole(userId, serverId, memberId, roleId),
      ).rejects.toThrow(ConflictException);

      expect(serversGateway.emitMemberRolesUpdate).not.toHaveBeenCalled();
    });

    it('rejects assigning a role the member already has', async () => {
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        serverId,
        roles: [{ id: roleId }],
      });
      prisma.role.findUnique.mockResolvedValue({ id: roleId, serverId });

      await expect(
        service.assignRole(userId, serverId, memberId, roleId),
      ).rejects.toThrow(ConflictException);
    });

    it('rejects assigning a role from a different server', async () => {
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        serverId,
        roles: [],
      });
      prisma.role.findUnique.mockResolvedValue({
        id: roleId,
        serverId: 'other-server',
      });

      await expect(
        service.assignRole(userId, serverId, memberId, roleId),
      ).rejects.toThrow(NotFoundException);
    });

    it('rejects unassigning a role the member does not have', async () => {
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        serverId,
        roles: [],
      });
      prisma.role.findUnique.mockResolvedValue({ id: roleId, serverId });

      await expect(
        service.unassignRole(userId, serverId, memberId, roleId),
      ).rejects.toThrow(NotFoundException);
    });

    it('unassigns a role the member currently has', async () => {
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        serverId,
        userId: 'target-user',
        roles: [{ id: roleId }],
      });
      prisma.role.findUnique.mockResolvedValue({ id: roleId, serverId });
      prisma.role.update.mockResolvedValue({ id: roleId });

      await service.unassignRole(userId, serverId, memberId, roleId);

      expect(prisma.role.update).toHaveBeenCalledWith({
        where: { id: roleId },
        data: { members: { disconnect: { id: memberId } } },
      });
      expect(serversGateway.emitMemberRolesUpdate).toHaveBeenCalledWith(
        expect.objectContaining({ serverId, memberId, userId: 'target-user' }),
      );
    });

    it('treats a concurrent missing disconnect (P2017) as already-unassigned without emitting', async () => {
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        serverId,
        userId: 'target-user',
        roles: [{ id: roleId }],
      });
      prisma.role.findUnique.mockResolvedValue({ id: roleId, serverId });
      prisma.role.update.mockRejectedValue(
        new Prisma.PrismaClientKnownRequestError(
          'The records for relation are not connected',
          {
            code: 'P2017',
            clientVersion: 'test',
          },
        ),
      );

      await expect(
        service.unassignRole(userId, serverId, memberId, roleId),
      ).rejects.toThrow(NotFoundException);

      expect(serversGateway.emitMemberRolesUpdate).not.toHaveBeenCalled();
    });

    it('rejects operating on a member from a different server', async () => {
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        serverId: 'other-server',
        roles: [],
      });

      await expect(
        service.assignRole(userId, serverId, memberId, roleId),
      ).rejects.toThrow(NotFoundException);
    });
  });

  describe('updateRole', () => {
    it('emits role:update with the updated role after a successful write', async () => {
      prisma.role.findUnique.mockResolvedValue({
        id: roleId,
        serverId,
        name: 'Moderator',
        permissions: {},
      });
      prisma.role.update.mockResolvedValue({
        id: roleId,
        name: 'Moderator',
        color: '#000',
        position: 1,
      });

      await service.updateRole(userId, roleId, { color: '#000' });

      expect(serversGateway.emitRoleUpdate).toHaveBeenCalledWith({
        serverId,
        role: { id: roleId, name: 'Moderator', color: '#000', position: 1 },
      });
    });

    it('does not emit role:update when the permission check fails', async () => {
      prisma.role.findUnique.mockResolvedValue({ id: roleId, serverId, permissions: {} });
      permissionsService.assertPermission.mockRejectedValue(
        new ForbiddenException(),
      );

      await expect(
        service.updateRole('stranger', roleId, { color: '#000' }),
      ).rejects.toThrow(ForbiddenException);

      expect(serversGateway.emitRoleUpdate).not.toHaveBeenCalled();
      expect(prisma.role.update).not.toHaveBeenCalled();
    });
  });

  describe('deleteRole', () => {
    it('requires the manageRoles permission using the role\'s own server', async () => {
      prisma.role.findUnique.mockResolvedValue({ id: roleId, serverId });
      prisma.role.delete.mockResolvedValue({ id: roleId });

      await service.deleteRole(userId, roleId);

      expect(permissionsService.assertPermission).toHaveBeenCalledWith(
        userId,
        serverId,
        'manageRoles',
        expect.any(String),
      );
      expect(prisma.role.delete).toHaveBeenCalledWith({ where: { id: roleId } });
      expect(serversGateway.emitRoleDelete).toHaveBeenCalledWith({
        serverId,
        roleId,
      });
    });

    it('throws NotFoundException for a non-existent role', async () => {
      prisma.role.findUnique.mockResolvedValue(null);

      await expect(service.deleteRole(userId, 'missing-role')).rejects.toThrow(
        NotFoundException,
      );
      expect(serversGateway.emitRoleDelete).not.toHaveBeenCalled();
    });
  });
});
