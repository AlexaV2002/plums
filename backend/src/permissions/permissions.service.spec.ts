import { ForbiddenException, NotFoundException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { PrismaService } from '../prisma/prisma.service';
import { PermissionsService } from './permissions.service';

describe('PermissionsService', () => {
  let service: PermissionsService;
  let prisma: {
    server: { findUnique: jest.Mock };
    serverMember: { findUnique: jest.Mock };
  };

  const serverId = 'server-1';
  const ownerId = 'owner-1';
  const memberId = 'member-1';

  beforeEach(async () => {
    prisma = {
      server: { findUnique: jest.fn() },
      serverMember: { findUnique: jest.fn() },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        PermissionsService,
        { provide: PrismaService, useValue: prisma },
      ],
    }).compile();

    service = module.get<PermissionsService>(PermissionsService);
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  it('throws NotFoundException when the server does not exist', async () => {
    prisma.server.findUnique.mockResolvedValue(null);

    await expect(service.getServerOrThrow(serverId)).rejects.toThrow(
      NotFoundException,
    );
  });

  it('grants the owner every permission, even with no roles', async () => {
    prisma.server.findUnique.mockResolvedValue({ id: serverId, ownerId });

    const permissions = await service.getEffectivePermissions(
      ownerId,
      serverId,
    );

    expect(Object.values(permissions).every((value) => value === true)).toBe(
      true,
    );
    expect(prisma.serverMember.findUnique).not.toHaveBeenCalled();
  });

  it('denies every permission to a member with no assigned roles', async () => {
    prisma.server.findUnique.mockResolvedValue({ id: serverId, ownerId });
    prisma.serverMember.findUnique.mockResolvedValue({
      id: memberId,
      roles: [],
    });

    const permissions = await service.getEffectivePermissions(
      memberId,
      serverId,
    );

    expect(Object.values(permissions).every((value) => value === false)).toBe(
      true,
    );
  });

  it('denies every permission to a user who is not a member at all', async () => {
    prisma.server.findUnique.mockResolvedValue({ id: serverId, ownerId });
    prisma.serverMember.findUnique.mockResolvedValue(null);

    const permissions = await service.getEffectivePermissions(
      'stranger',
      serverId,
    );

    expect(Object.values(permissions).every((value) => value === false)).toBe(
      true,
    );
  });

  it('unions permissions across all roles assigned to the member', async () => {
    prisma.server.findUnique.mockResolvedValue({ id: serverId, ownerId });
    prisma.serverMember.findUnique.mockResolvedValue({
      id: memberId,
      roles: [
        { permissions: { manageChannels: true } },
        { permissions: { manageBans: true } },
      ],
    });

    const permissions = await service.getEffectivePermissions(
      memberId,
      serverId,
    );

    expect(permissions.manageChannels).toBe(true);
    expect(permissions.manageBans).toBe(true);
    expect(permissions.manageServer).toBe(false);
    expect(permissions.manageRoles).toBe(false);
  });

  it('ignores malformed role permissions instead of throwing', async () => {
    prisma.server.findUnique.mockResolvedValue({ id: serverId, ownerId });
    prisma.serverMember.findUnique.mockResolvedValue({
      id: memberId,
      roles: [{ permissions: null }, { permissions: ['not', 'an', 'object'] }],
    });

    const permissions = await service.getEffectivePermissions(
      memberId,
      serverId,
    );

    expect(Object.values(permissions).every((value) => value === false)).toBe(
      true,
    );
  });

  it('does not grant permissions for non-boolean stored values', async () => {
    prisma.server.findUnique.mockResolvedValue({ id: serverId, ownerId });
    prisma.serverMember.findUnique.mockResolvedValue({
      id: memberId,
      roles: [{ permissions: { manageRoles: 'false', manageBans: 1 } }],
    });

    await expect(
      service.assertPermission(memberId, serverId, 'manageRoles', 'Denied'),
    ).rejects.toThrow(ForbiddenException);
    const permissions = await service.getEffectivePermissions(memberId, serverId);
    expect(permissions.manageBans).toBe(false);
  });

  describe('assertPermission', () => {
    it('allows the owner and returns the server without checking membership', async () => {
      prisma.server.findUnique.mockResolvedValue({ id: serverId, ownerId });

      const server = await service.assertPermission(
        ownerId,
        serverId,
        'manageRoles',
        'Только владелец может управлять ролями',
      );

      expect(server.ownerId).toBe(ownerId);
      expect(prisma.serverMember.findUnique).not.toHaveBeenCalled();
    });

    it('allows a member whose role grants the required permission', async () => {
      prisma.server.findUnique.mockResolvedValue({ id: serverId, ownerId });
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        roles: [{ permissions: { manageChannels: true } }],
      });

      await expect(
        service.assertPermission(
          memberId,
          serverId,
          'manageChannels',
          'Недостаточно прав',
        ),
      ).resolves.toBeDefined();
    });

    it('throws ForbiddenException with the given message when permission is missing', async () => {
      prisma.server.findUnique.mockResolvedValue({ id: serverId, ownerId });
      prisma.serverMember.findUnique.mockResolvedValue({
        id: memberId,
        roles: [{ permissions: { manageChannels: true } }],
      });

      await expect(
        service.assertPermission(
          memberId,
          serverId,
          'manageBans',
          'Недостаточно прав для бана',
        ),
      ).rejects.toThrow(ForbiddenException);
    });
  });
});
