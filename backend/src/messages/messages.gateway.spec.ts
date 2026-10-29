import { PrismaService } from '../prisma/prisma.service';
import { MessagesGateway } from './messages.gateway';

describe('MessagesGateway rooms', () => {
  const prisma = {
    channel: { findUnique: jest.fn() },
    serverMember: { findUnique: jest.fn() },
  };
  const gateway = new MessagesGateway(prisma as unknown as PrismaService);

  beforeEach(() => jest.clearAllMocks());

  const client = () => ({
    data: {
      userId: 'user-1',
      authExpiresAt: Date.now() + 60000,
      identityVersion: 1,
    },
    join: jest.fn(),
    emit: jest.fn(),
  });
  const channel = (canView: boolean) => ({
    id: 'channel-1',
    serverId: 'server-1',
    permissions: { canView },
    server: { ownerId: 'owner' },
  });

  it('rejects unidentified sockets, strangers and hidden channels', async () => {
    const socket = client();
    const ack = jest.fn();
    delete (socket.data as { userId?: string }).userId;
    await gateway.joinChannel({ channelId: 'channel-1' }, socket as never, ack);
    expect(prisma.channel.findUnique).not.toHaveBeenCalled();
    expect(ack).toHaveBeenLastCalledWith({ joined: false, reason: 'session_required' });

    socket.data.userId = 'user-1';
    prisma.channel.findUnique.mockResolvedValue(channel(true));
    prisma.serverMember.findUnique
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce({ id: 'member-1' });
    await gateway.joinChannel({ channelId: 'channel-1' }, socket as never, ack);
    expect(socket.join).not.toHaveBeenCalled();
    expect(ack).toHaveBeenLastCalledWith({
      joined: false,
      channelId: 'channel-1',
      reason: 'forbidden',
    });

    prisma.channel.findUnique.mockResolvedValue(channel(false));
    await gateway.joinChannel({ channelId: 'channel-1' }, socket as never, ack);
    expect(socket.join).not.toHaveBeenCalled();
    expect(ack).toHaveBeenLastCalledWith({
      joined: false,
      channelId: 'channel-1',
      reason: 'forbidden',
    });
  });

  it('acknowledges channel join only after the room is joined', async () => {
    const socket = client();
    const ack = jest.fn();
    let finishJoin!: () => void;
    socket.join.mockReturnValue(
      new Promise<void>((resolve) => {
        finishJoin = resolve;
      }),
    );
    prisma.channel.findUnique.mockResolvedValue(channel(true));
    prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-1' });

    const joining = gateway.joinChannel({ channelId: 'channel-1' }, socket as never, ack);
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(socket.join).toHaveBeenCalledWith('channel:channel-1');
    expect(ack).not.toHaveBeenCalled();

    finishJoin();
    await joining;
    expect(ack).toHaveBeenCalledWith({ joined: true, channelId: 'channel-1' });
  });

  it('allows a member of a visible channel and the owner of a hidden channel', async () => {
    const socket = client();
    prisma.serverMember.findUnique.mockResolvedValue({ id: 'member-1' });
    prisma.channel.findUnique
      .mockResolvedValueOnce(channel(true))
      .mockResolvedValueOnce(channel(false));
    await gateway.joinChannel({ channelId: 'channel-1' }, socket as never);
    expect(socket.join).toHaveBeenCalledWith('channel:channel-1');

    socket.data.userId = 'owner';
    await gateway.joinChannel({ channelId: 'channel-1' }, socket as never);
    expect(socket.join).toHaveBeenCalledTimes(2);
  });

  it('rejects a channel join after JWT expiry', async () => {
    const socket = client();
    socket.data.authExpiresAt = Date.now() - 1;
    await gateway.joinChannel({ channelId: 'channel-1' }, socket as never);
    expect(prisma.channel.findUnique).not.toHaveBeenCalled();
    expect(socket.join).not.toHaveBeenCalled();
  });
});
