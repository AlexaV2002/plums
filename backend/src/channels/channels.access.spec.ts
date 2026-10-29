import { ChannelsGateway } from './channels.gateway';
import { ChannelsService } from './channels.service';

describe('channel room revocation', () => {
  it('removes non-owners when canView is revoked', async () => {
    const owner = { data: { userId: 'owner' }, leave: jest.fn(), emit: jest.fn() };
    const member = { data: { userId: 'member' }, leave: jest.fn(), emit: jest.fn() };
    const fetchSockets = jest.fn().mockResolvedValue([owner, member]);
    const gatewayPrisma = {
      server: { findUnique: jest.fn().mockResolvedValue({ ownerId: 'owner' }) },
    };
    const gateway = new ChannelsGateway(gatewayPrisma as never);
    gateway.server = {
      in: jest.fn().mockReturnValue({ fetchSockets }),
    } as never;

    const prisma = {
      channel: {
        findUnique: jest.fn().mockResolvedValue({
          id: 'channel-1',
          serverId: 'server-1',
          permissions: { canView: true },
        }),
        update: jest.fn().mockResolvedValue({
          id: 'channel-1',
          serverId: 'server-1',
          permissions: { canView: false },
        }),
      },
      server: { findUnique: jest.fn().mockResolvedValue({ ownerId: 'owner' }) },
    };
    const service = new ChannelsService(prisma as never, gateway, {
      assertPermission: jest.fn().mockResolvedValue({}),
    } as never);
    const emitChannelUpdate = jest.fn();
    gateway.emitChannelUpdate = emitChannelUpdate;

    await service.updateChannelPermissions('owner', 'channel-1', {
      canView: false,
    });
    expect(owner.leave).not.toHaveBeenCalled();
    expect(member.leave).toHaveBeenCalledWith('channel:channel-1');
    expect(owner.emit).not.toHaveBeenCalled();
    expect(member.emit).toHaveBeenCalledWith('channel:delete', {
      id: 'channel-1',
      serverId: 'server-1',
    });
    // Full metadata still goes only to the owner after the channel is hidden.
    expect(emitChannelUpdate).toHaveBeenCalledWith(
      'server-1',
      expect.objectContaining({ id: 'channel-1' }),
      true,
    );
  });

  it('keeps broadcasting to the whole server room for visible channels', async () => {
    const gatewayPrisma = {
      server: { findUnique: jest.fn().mockResolvedValue({ ownerId: 'owner' }) },
    };
    const gateway = new ChannelsGateway(gatewayPrisma as never);
    gateway.server = { in: jest.fn() } as never;

    const prisma = {
      channel: {
        findUnique: jest.fn().mockResolvedValue({
          id: 'channel-2',
          serverId: 'server-1',
          permissions: { canView: true },
        }),
        update: jest.fn().mockResolvedValue({
          id: 'channel-2',
          serverId: 'server-1',
          name: 'renamed',
          permissions: { canView: true },
        }),
      },
    };
    const service = new ChannelsService(prisma as never, gateway, {
      assertPermission: jest.fn().mockResolvedValue({}),
    } as never);
    const emitChannelUpdate = jest.fn();
    gateway.emitChannelUpdate = emitChannelUpdate;

    await service.updateChannel('owner', 'channel-2', { name: 'renamed' });

    expect(emitChannelUpdate).toHaveBeenCalledWith(
      'server-1',
      expect.objectContaining({ id: 'channel-2' }),
      false,
    );
  });
});
