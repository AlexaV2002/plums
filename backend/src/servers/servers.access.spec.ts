import { ServersService } from './servers.service';

describe('server room revocation', () => {
  const member = { id: 'member-1', userId: 'member', serverId: 'server-1' };
  const gateway = {
    emitMemberLeave: jest.fn(),
    evictUserFromServer: jest.fn(),
  };
  const prisma = {
    serverMember: { findUnique: jest.fn(), delete: jest.fn() },
    serverBan: { findUnique: jest.fn(), create: jest.fn() },
    $transaction: jest.fn(),
  };
  const permissions = {
    getServerOrThrow: jest
      .fn()
      .mockResolvedValue({ id: 'server-1', ownerId: 'owner' }),
    assertPermission: jest
      .fn()
      .mockResolvedValue({ id: 'server-1', ownerId: 'owner' }),
  };
  const service = new ServersService(
    prisma as never,
    gateway as never,
    permissions as never,
  );

  beforeEach(() => {
    jest.clearAllMocks();
    prisma.serverMember.findUnique.mockResolvedValue(member);
    prisma.serverBan.findUnique.mockResolvedValue(null);
  });

  it('evicts a member after leaving', async () => {
    await service.leaveServer('member', 'server-1');
    expect(gateway.emitMemberLeave).toHaveBeenCalledWith(
      expect.objectContaining({ reason: 'leave' }),
    );
    expect(gateway.evictUserFromServer).toHaveBeenCalledWith(
      'server-1',
      'member',
    );
  });

  it('evicts a kicked member', async () => {
    await service.kickServerMember('owner', 'server-1', 'member-1');
    expect(gateway.emitMemberLeave).toHaveBeenCalledWith(
      expect.objectContaining({ reason: 'kick' }),
    );
    expect(gateway.evictUserFromServer).toHaveBeenCalledWith(
      'server-1',
      'member',
    );
  });

  it('evicts a banned member', async () => {
    await service.banServerMember('owner', 'server-1', 'member', {
      reason: 'spam',
    });
    expect(gateway.emitMemberLeave).toHaveBeenCalledWith(
      expect.objectContaining({ reason: 'ban' }),
    );
    expect(gateway.evictUserFromServer).toHaveBeenCalledWith(
      'server-1',
      'member',
    );
  });
});
