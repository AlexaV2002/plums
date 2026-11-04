import { PrismaService } from '../prisma/prisma.service';
import { ServersGateway } from './servers.gateway';

describe('ServersGateway rooms', () => {
  const prisma = {
    serverMember: { findUnique: jest.fn() },
    channel: { findMany: jest.fn() },
  };
  const gateway = new ServersGateway(prisma as unknown as PrismaService);

  beforeEach(() => jest.clearAllMocks());

  it('requires identification and membership for server:join', async () => {
    const client = { data: {}, join: jest.fn(), emit: jest.fn() };
    await gateway.joinServer({ serverId: 'server-1' }, client as never);
    expect(prisma.serverMember.findUnique).not.toHaveBeenCalled();
    expect(client.join).not.toHaveBeenCalled();

    client.data = {
      userId: 'user-1',
      authExpiresAt: Date.now() + 60000,
      identityVersion: 1,
    };
    prisma.serverMember.findUnique
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce({ id: 'member-1' });
    await gateway.joinServer({ serverId: 'server-1' }, client as never);
    expect(client.join).not.toHaveBeenCalled();
    await gateway.joinServer({ serverId: 'server-1' }, client as never);
    expect(client.join).toHaveBeenCalledWith('server:server-1');
  });

  it('evicts the removed user from server and its channels only', async () => {
    prisma.channel.findMany.mockResolvedValue([{ id: 'channel-1' }]);
    const target = {
      data: { userId: 'user-1' },
      rooms: new Set(['server:server-1', 'channel:channel-1', 'channel:other']),
      leave: jest.fn(),
    };
    const other = {
      data: { userId: 'user-2' },
      rooms: new Set(['server:server-1']),
      leave: jest.fn(),
    };
    gateway.server = {
      fetchSockets: jest.fn().mockResolvedValue([target, other]),
    } as never;

    await gateway.evictUserFromServer('server-1', 'user-1');
    expect(target.leave).toHaveBeenCalledWith('server:server-1');
    expect(target.leave).toHaveBeenCalledWith('channel:channel-1');
    expect(target.leave).not.toHaveBeenCalledWith('channel:other');
    expect(other.leave).not.toHaveBeenCalled();
  });

  it('rejects a join after JWT expiry even before the expiry timer runs', async () => {
    const expireSession = jest.fn();
    const client = {
      data: {
        userId: 'user-1',
        authExpiresAt: Date.now() - 1,
        identityVersion: 1,
        expireSession,
      },
      join: jest.fn(),
    };
    await gateway.joinServer({ serverId: 'server-1' }, client as never);
    expect(expireSession).toHaveBeenCalledTimes(1);
    expect(prisma.serverMember.findUnique).not.toHaveBeenCalled();
    expect(client.join).not.toHaveBeenCalled();
  });

  it('rejects an in-flight join after account identity changes', async () => {
    let finishLookup!: (member: { id: string }) => void;
    prisma.serverMember.findUnique.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finishLookup = resolve;
        }),
    );
    const client = {
      data: {
        userId: 'user-1',
        authExpiresAt: Date.now() + 60000,
        identityVersion: 1,
      },
      join: jest.fn(),
    };
    const joining = gateway.joinServer(
      { serverId: 'server-1' },
      client as never,
    );
    client.data.userId = 'user-2';
    client.data.identityVersion = 2;
    finishLookup({ id: 'member-1' });
    await joining;
    expect(client.join).not.toHaveBeenCalled();
  });
});
