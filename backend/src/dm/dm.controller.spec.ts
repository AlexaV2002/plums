import { JwtService } from '@nestjs/jwt';
import { Test, TestingModule } from '@nestjs/testing';
import { DmController } from './dm.controller';
import { DmService } from './dm.service';

describe('DmController', () => {
  let controller: DmController;
  let dmService: {
    findConversations: jest.Mock;
    getOrCreateConversation: jest.Mock;
    findMessages: jest.Mock;
    sendMessage: jest.Mock;
    removeMessage: jest.Mock;
  };

  const user = { sub: 'user-a', email: 'user@example.com' };

  beforeEach(async () => {
    dmService = {
      findConversations: jest.fn(),
      getOrCreateConversation: jest.fn(),
      findMessages: jest.fn(),
      sendMessage: jest.fn(),
      removeMessage: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [DmController],
      providers: [
        { provide: DmService, useValue: dmService },
        { provide: JwtService, useValue: {} },
      ],
    }).compile();

    controller = module.get<DmController>(DmController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  it('findConversations delegates to the service with the current user', async () => {
    dmService.findConversations.mockResolvedValue([]);

    await expect(controller.findConversations(user)).resolves.toEqual([]);
    expect(dmService.findConversations).toHaveBeenCalledWith(user.sub);
  });

  it('getOrCreateConversation delegates the body to the service', async () => {
    dmService.getOrCreateConversation.mockResolvedValue({ id: 'c1' });

    await expect(
      controller.getOrCreateConversation(user, { userId: 'user-b' }),
    ).resolves.toEqual({ id: 'c1' });
    expect(dmService.getOrCreateConversation).toHaveBeenCalledWith(
      user.sub,
      { userId: 'user-b' },
    );
  });

  it('findMessages passes the query through', async () => {
    dmService.findMessages.mockResolvedValue([]);

    await controller.findMessages(user, 'c1', { limit: 10, before: 'm1' });

    expect(dmService.findMessages).toHaveBeenCalledWith('c1', user.sub, {
      limit: 10,
      before: 'm1',
    });
  });

  it('sendMessage delegates the body to the service', async () => {
    dmService.sendMessage.mockResolvedValue({ id: 'm1' });

    await expect(
      controller.sendMessage(user, 'c1', { content: 'hi' }),
    ).resolves.toEqual({ id: 'm1' });
    expect(dmService.sendMessage).toHaveBeenCalledWith('c1', user.sub, {
      content: 'hi',
    });
  });

  it('removeMessage delegates the message id', async () => {
    dmService.removeMessage.mockResolvedValue(undefined);

    await controller.removeMessage(user, 'm1');

    expect(dmService.removeMessage).toHaveBeenCalledWith('m1', user.sub);
  });
});
