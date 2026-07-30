import { ForbiddenException, NotFoundException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { PermissionsService } from '../permissions/permissions.service';
import { PrismaService } from '../prisma/prisma.service';
import { ServersGateway } from './servers.gateway';
import { ServersService } from './servers.service';

describe('ServersService', () => {
  let service: ServersService;
  let prisma: {
    server: { findUnique: jest.Mock };
    serverMember: { findUnique: jest.Mock; findMany: jest.Mock };
  };
  let permissionsService: {
    getServerOrThrow: jest.Mock;
    assertPermission: jest.Mock;
  };
  let serversGateway: {
    emitMemberLeave: jest.Mock;
    emitMemberJoin: jest.Mock;
  };

  const serverId = 'server-1';
  const userId = 'user-1';

  beforeEach(async () => {
    prisma = {
      server: { findUnique: jest.fn() },
      serverMember: { findUnique: jest.fn(), findMany: jest.fn() },
    };

    permissionsService = {
      getServerOrThrow: jest.fn().mockResolvedValue({ id: serverId, ownerId: userId }),
      assertPermission: jest.fn().mockResolvedValue({ id: serverId, ownerId: userId }),
    };

    serversGateway = {
      emitMemberLeave: jest.fn(),
      emitMemberJoin: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ServersService,
        { provide: PrismaService, useValue: prisma },
        { provide: PermissionsService, useValue: permissionsService },
        { provide: ServersGateway, useValue: serversGateway },
      ],
    }).compile();

    service = module.get<ServersService>(ServersService);
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('getServerMembers', () => {
    it('selects each member\'s roles limited to id, name, color and position', async () => {
      prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-1', userId });
      prisma.serverMember.findMany.mockResolvedValue([]);

      await service.getServerMembers(userId, serverId);

      expect(prisma.serverMember.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { serverId },
          select: expect.objectContaining({
            roles: {
              select: { id: true, name: true, color: true, position: true },
              orderBy: { position: 'asc' },
            },
          }),
        }),
      );
    });

    it('rejects a user who is not a member of the server', async () => {
      prisma.serverMember.findUnique.mockResolvedValue(null);

      await expect(
        service.getServerMembers('stranger', serverId),
      ).rejects.toThrow(ForbiddenException);
    });
  });

  describe('getServerById', () => {
    it('includes member roles limited to id, name, color and position', async () => {
      prisma.server.findUnique.mockResolvedValue({
        id: serverId,
        members: [{ userId }],
      });

      await service.getServerById(userId, serverId);

      expect(prisma.server.findUnique).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: serverId },
          include: expect.objectContaining({
            members: expect.objectContaining({
              include: expect.objectContaining({
                roles: {
                  select: { id: true, name: true, color: true, position: true },
                  orderBy: { position: 'asc' },
                },
              }),
            }),
          }),
        }),
      );
    });

    it('throws NotFoundException for a non-existent server', async () => {
      prisma.server.findUnique.mockResolvedValue(null);

      await expect(
        service.getServerById(userId, 'missing-server'),
      ).rejects.toThrow(NotFoundException);
    });

    it('rejects a user who is not a member of the server', async () => {
      prisma.server.findUnique.mockResolvedValue({
        id: serverId,
        members: [{ userId: 'someone-else' }],
      });

      await expect(
        service.getServerById(userId, serverId),
      ).rejects.toThrow(ForbiddenException);
    });
  });
});
