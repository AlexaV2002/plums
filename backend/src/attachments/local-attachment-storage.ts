import { Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import type { Dirent } from 'node:fs';
import * as path from 'node:path';

export interface AttachmentStorage {
  put(data: Buffer): Promise<string>;
  read(key: string): Promise<Buffer>;
  remove(key: string): Promise<void>;
  oldKeys(before: Date): Promise<string[]>;
}
export const ATTACHMENT_STORAGE = Symbol('ATTACHMENT_STORAGE');

@Injectable()
export class LocalAttachmentStorage implements AttachmentStorage {
  private readonly root: string;

  constructor() {
    const base = path.resolve(process.cwd(), '.tmp');
    const isTest = process.env.NODE_ENV === 'test';
    this.root = path.resolve(
      process.env.ATTACHMENT_STORAGE_DIR ??
        (isTest
          ? path.join(base, `attachments-tests-${process.pid}`)
          : path.join(process.cwd(), 'storage', 'attachments')),
    );
    if (isTest) {
      const relative = path.relative(base, this.root);
      if (
        !relative ||
        relative === '..' ||
        relative.startsWith(`..${path.sep}`) ||
        path.isAbsolute(relative)
      ) {
        throw new Error('Test attachment storage must be inside backend/.tmp');
      }
    }
  }

  private file(key: string): string {
    if (
      !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
        key,
      )
    ) {
      throw new Error('Invalid storage key');
    }
    return path.join(this.root, key);
  }

  async put(data: Buffer): Promise<string> {
    await fs.mkdir(this.root, { recursive: true, mode: 0o700 });
    const key = randomUUID();
    await fs.writeFile(this.file(key), data, { flag: 'wx', mode: 0o600 });
    return key;
  }

  read(key: string): Promise<Buffer> {
    return fs.readFile(this.file(key));
  }

  async remove(key: string): Promise<void> {
    try {
      await fs.unlink(this.file(key));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
    }
  }

  async oldKeys(before: Date): Promise<string[]> {
    let entries: Dirent[];
    try {
      entries = await fs.readdir(this.root, { withFileTypes: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
      throw error;
    }
    const keys: string[] = [];
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      try {
        const filename = this.file(entry.name);
        const stat = await fs.lstat(filename);
        if (stat.isFile() && stat.mtime < before) keys.push(entry.name);
      } catch {
        // Ignore files which are not managed keys or disappeared meanwhile.
      }
    }
    return keys;
  }
}
