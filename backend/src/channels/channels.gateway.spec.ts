import { ChannelsGateway } from './channels.gateway';

describe('ChannelsGateway channel event targeting', () => {
  function makeSockets() {
    return {
      owner: { data: { userId: 'owner' }, emit: jest.fn() },
      member: { data: { userId: 'member' }, emit: jest.fn() },
    };
  }

  it('broadcasts visible channel events to the whole server room', async () => {
    const gateway = new ChannelsGateway({
      server: { findUnique: jest.fn() },
    } as never);
    const roomEmit = jest.fn();
    const to = jest.fn().mockReturnValue({ emit: roomEmit });
    gateway.server = { to } as never;

    const payload = { id: 'channel-1', permissions: { canView: true } };
    await gateway.emitChannelUpdate('server-1', payload, false);

    expect(to).toHaveBeenCalledWith('server:server-1');
    expect(roomEmit).toHaveBeenCalledWith('channel:update', payload);
  });

  it('sends hidden channel events only to the server owner, not the whole room', async () => {
    const { owner, member } = makeSockets();
    const fetchSockets = jest.fn().mockResolvedValue([owner, member]);
    const roomEmit = jest.fn();
    const to = jest.fn().mockReturnValue({ emit: roomEmit });
    const inRoom = jest.fn().mockReturnValue({ fetchSockets });
    const findUnique = jest.fn().mockResolvedValue({ ownerId: 'owner' });
    const gateway = new ChannelsGateway({ server: { findUnique } } as never);
    gateway.server = { to, in: inRoom } as never;

    const payload = { id: 'channel-1', permissions: { canView: false } };
    await gateway.emitChannelUpdate('server-1', payload, true);

    expect(roomEmit).not.toHaveBeenCalled();
    expect(findUnique).toHaveBeenCalledWith({
      where: { id: 'server-1' },
      select: { ownerId: true },
    });
    expect(owner.emit).toHaveBeenCalledWith('channel:update', payload);
    expect(member.emit).not.toHaveBeenCalled();
  });

  it('does nothing for hidden channel events if the server no longer exists', async () => {
    const roomEmit = jest.fn();
    const to = jest.fn().mockReturnValue({ emit: roomEmit });
    const findUnique = jest.fn().mockResolvedValue(null);
    const gateway = new ChannelsGateway({ server: { findUnique } } as never);
    gateway.server = { to, in: jest.fn() } as never;

    await gateway.emitChannelDelete(
      'server-1',
      { id: 'channel-1' },
      true,
    );

    expect(roomEmit).not.toHaveBeenCalled();
  });
});
