import { promises as fs } from 'node:fs';
import * as path from 'node:path';
import { LocalAttachmentStorage } from './local-attachment-storage';

describe('test attachment storage isolation', () => {
  const original = process.env.ATTACHMENT_STORAGE_DIR;

  afterEach(() => {
    if (original === undefined) delete process.env.ATTACHMENT_STORAGE_DIR;
    else process.env.ATTACHMENT_STORAGE_DIR = original;
  });

  it('stores files under backend/.tmp by default in tests', async () => {
    delete process.env.ATTACHMENT_STORAGE_DIR;
    const storage = new LocalAttachmentStorage();
    const data = Buffer.from('isolated');
    const key = await storage.put(data);
    const testPath = path.join(
      process.cwd(),
      '.tmp',
      `attachments-tests-${process.pid}`,
      key,
    );
    try {
      expect(await fs.readFile(testPath)).toEqual(data);
    } finally {
      await storage.remove(key);
      await fs.rmdir(path.dirname(testPath)).catch(() => undefined);
    }
  });

  it('rejects the normal storage path when running tests', () => {
    process.env.ATTACHMENT_STORAGE_DIR = path.join(
      process.cwd(),
      'storage',
      'attachments',
    );
    expect(() => new LocalAttachmentStorage()).toThrow(
      'Test attachment storage',
    );
  });
});
