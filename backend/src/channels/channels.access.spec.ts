import { ChannelsGateway } from './channels.gateway';
import { ChannelsService } from './channels.service';

describe('channel room revocation', () => {
  it('removes non-owners when canView is revoked', async () => {
    const owner = { data: { userId: 'owner' }, leave: jest.fn() };
    const member = { data: { userId: 'member' }, leave: jest.fn() };
    const fetchSockets = jest.fn().mockResolvedValue([owner, member]);
    const gateway = new ChannelsGateway();
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
    expect(emitChannelUpdate).toHaveBeenCalled();
  });
});
