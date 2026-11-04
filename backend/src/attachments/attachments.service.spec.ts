import { BadRequestException, ForbiddenException } from '@nestjs/common';
import { ChannelType } from '@prisma/client';
import sharp from 'sharp';
import { AttachmentsService } from './attachments.service';

describe('AttachmentsService', () => {
  const prisma = {
    channel: { findUnique: jest.fn() },
    serverMember: { findUnique: jest.fn() },
    attachment: {
      create: jest.fn(),
      deleteMany: jest.fn(),
      findUnique: jest.fn(),
    },
    attachmentCleanup: {
      findMany: jest.fn(),
      deleteMany: jest.fn(),
      updateMany: jest.fn(),
      findUnique: jest.fn(),
    },
  };
  const storage = {
    put: jest.fn(),
    read: jest.fn(),
    remove: jest.fn(),
    oldKeys: jest.fn(),
  };
  let service: AttachmentsService;
  let validImage: Buffer;

  beforeAll(async () => {
    validImage = await sharp({
      create: { width: 2, height: 2, channels: 3, background: '#123456' },
    })
      .png()
      .toBuffer();
  });
  beforeEach(() => {
    jest.resetAllMocks();
    service = new AttachmentsService(prisma as never, storage);
    prisma.channel.findUnique.mockResolvedValue({
      id: 'channel',
      serverId: 'server',
      type: ChannelType.TEXT,
      permissions: null,
      server: { ownerId: 'owner' },
    });
    prisma.serverMember.findUnique.mockResolvedValue({ id: 'member' });
    storage.put.mockResolvedValue('storage-key');
    storage.remove.mockResolvedValue(undefined);
    storage.oldKeys.mockResolvedValue([]);
    prisma.attachmentCleanup.findMany.mockResolvedValue([]);
  });

  it('rejects spoofed image content before writing to storage', async () => {
    await expect(
      service.upload('channel', 'member', {
        buffer: Buffer.from('fake'),
        size: 4,
        originalname: 'photo.png',
      }),
    ).rejects.toThrow(BadRequestException);
    expect(storage.put).not.toHaveBeenCalled();
  });

  it('removes stored bytes when metadata insertion fails', async () => {
    prisma.attachment.create.mockRejectedValue(new Error('db unavailable'));
    await expect(
      service.upload('channel', 'member', {
        buffer: validImage,
        size: validImage.length,
        originalname: 'photo.png',
      }),
    ).rejects.toThrow('db unavailable');
    expect(storage.remove).toHaveBeenCalledWith('storage-key');
  });

  it('removes uploaded bytes when channel access disappears during upload', async () => {
    prisma.serverMember.findUnique
      .mockResolvedValueOnce({ id: 'member' })
      .mockResolvedValueOnce(null);
    await expect(
      service.upload('channel', 'member', {
        buffer: validImage,
        size: validImage.length,
        originalname: 'photo.png',
      }),
    ).rejects.toThrow(ForbiddenException);
    expect(storage.remove).toHaveBeenCalledWith('storage-key');
    expect(prisma.attachment.create).not.toHaveBeenCalled();
  });

  it('retains failed cleanup work and retries it later', async () => {
    prisma.attachmentCleanup.findMany.mockResolvedValue([
      { storageKey: 'queued-key' },
    ]);
    storage.remove
      .mockRejectedValueOnce(new Error('disk unavailable'))
      .mockResolvedValueOnce(undefined);
    await service.cleanup();
    expect(prisma.attachmentCleanup.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { storageKey: 'queued-key' } }),
    );
    expect(prisma.attachmentCleanup.deleteMany).not.toHaveBeenCalled();
    await service.cleanup();
    expect(prisma.attachmentCleanup.deleteMany).toHaveBeenCalledWith({
      where: { storageKey: 'queued-key' },
    });
  });

  it('removes only orphaned old files, preserving live and queued keys', async () => {
    storage.oldKeys.mockResolvedValue(['live', 'queued', 'orphan']);
    prisma.attachment.findUnique.mockImplementation(
      ({ where }: { where: { storageKey: string } }) =>
        Promise.resolve(where.storageKey === 'live' ? { id: 'live' } : null),
    );
    prisma.attachmentCleanup.findUnique.mockImplementation(
      ({ where }: { where: { storageKey: string } }) =>
        Promise.resolve(
          where.storageKey === 'queued' ? { storageKey: 'queued' } : null,
        ),
    );
    await service.cleanup();
    expect(storage.remove).toHaveBeenCalledTimes(1);
    expect(storage.remove).toHaveBeenCalledWith('orphan');
  });
});
