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

    client.data = { userId: 'user-1' };
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
});
