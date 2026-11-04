import { BadRequestException, ForbiddenException } from '@nestjs/common';
import sharp from 'sharp';
import { ProfileImagesService } from './profile-images.service';

describe('ProfileImagesService', () => {
  const prisma = {
    user: { findUnique: jest.fn() },
    serverMember: { findUnique: jest.fn() },
    profileImage: { findUnique: jest.fn() },
    $transaction: jest.fn(),
  };
  const permissions = { assertPermission: jest.fn() };
  const storage = {
    put: jest.fn(),
    read: jest.fn(),
    remove: jest.fn(),
    oldKeys: jest.fn(),
  };
  const cleanup = { cleanup: jest.fn() };
  let service: ProfileImagesService;

  beforeEach(() => {
    jest.resetAllMocks();
    service = new ProfileImagesService(
      prisma as never,
      permissions as never,
      {} as never,
      cleanup as never,
      storage,
    );
    prisma.user.findUnique.mockResolvedValue({ id: 'alice' });
    permissions.assertPermission.mockResolvedValue({});
    cleanup.cleanup.mockResolvedValue(undefined);
  });

  it('rejects changes to another user', async () => {
    await expect(
      service.set({ userId: 'alice' }, 'bob'),
    ).rejects.toBeInstanceOf(ForbiddenException);
    expect(storage.put).not.toHaveBeenCalled();
  });

  it('requires manageServer before processing an icon', async () => {
    permissions.assertPermission.mockRejectedValue(new ForbiddenException());
    await expect(
      service.set({ serverId: 'server' }, 'bob'),
    ).rejects.toBeInstanceOf(ForbiddenException);
    expect(permissions.assertPermission).toHaveBeenCalledWith(
      'bob',
      'server',
      'manageServer',
      expect.any(String),
    );
    expect(storage.put).not.toHaveBeenCalled();
  });

  it('rejects scripts even when named as an image', async () => {
    const buffer = Buffer.from('<svg><script>alert(1)</script></svg>');
    await expect(
      service.set({ userId: 'alice' }, 'alice', {
        buffer,
        originalname: 'image.png',
        size: buffer.length,
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(storage.put).not.toHaveBeenCalled();
  });

  it('removes a saved file if the database transaction fails', async () => {
    const buffer = await sharp({
      create: { width: 1, height: 1, channels: 3, background: '#ffffff' },
    })
      .png()
      .toBuffer();
    storage.put.mockResolvedValue('key');
    prisma.$transaction.mockRejectedValue(new Error('database unavailable'));
    await expect(
      service.set({ userId: 'alice' }, 'alice', {
        buffer,
        originalname: 'x.png',
        size: buffer.length,
      }),
    ).rejects.toThrow('database unavailable');
    expect(storage.remove).toHaveBeenCalledWith('key');
  });

  it('denies an icon to nonmembers', async () => {
    prisma.profileImage.findUnique.mockResolvedValue({
      serverId: 'server',
      storageKey: 'key',
      mimeType: 'image/png',
    });
    prisma.serverMember.findUnique.mockResolvedValue(null);
    await expect(service.content('id', 'outsider')).rejects.toBeInstanceOf(
      ForbiddenException,
    );
    expect(storage.read).not.toHaveBeenCalled();
  });

  it('tags out-of-order notifications with their committed revision', async () => {
    const emit = jest.fn();
    const socket = {
      connected: true,
      data: {
        userId: 'member',
        identityVersion: 1,
        authExpiresAt: Date.now() + 60000,
      },
      emit,
    };
    const gateway = {
      server: { sockets: { sockets: new Map([['socket', socket]]) } },
    };
    service = new ProfileImagesService(
      prisma as never,
      permissions as never,
      gateway as never,
      cleanup as never,
      storage,
    );
    let revision = 0;
    const tx = {
      $queryRaw: jest.fn().mockResolvedValue([]),
      profileImage: { deleteMany: jest.fn().mockResolvedValue({ count: 1 }) },
      server: {
        update: jest
          .fn()
          .mockImplementation(() =>
            Promise.resolve({ profileImageRevision: ++revision }),
          ),
      },
    };
    prisma.$transaction.mockImplementation(
      (fn: (tx: unknown) => Promise<unknown>) => fn(tx),
    );
    let release!: (value: { id: string }) => void;
    const delayed = new Promise<{ id: string }>((resolve) => {
      release = resolve;
    });
    prisma.serverMember.findUnique
      .mockReturnValueOnce(delayed)
      .mockResolvedValueOnce({ id: 'member' });
    const first = service.remove({ serverId: 'server' }, 'owner');
    while (!prisma.serverMember.findUnique.mock.calls.length)
      await new Promise((resolve) => setImmediate(resolve));
    const second = await service.remove({ serverId: 'server' }, 'owner');
    release({ id: 'member' });
    const old = await first;
    expect([old.revision, second.revision]).toEqual([1, 2]);
    expect(
      emit.mock.calls.map(
        (call: unknown[]) => (call[1] as { revision: number }).revision,
      ),
    ).toEqual([2, 1]);
  });
});
