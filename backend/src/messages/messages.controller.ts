import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { CreateMessageDto } from './dto/create-message.dto';
import { MessagesService } from './messages.service';
import { UpdateMessageDto } from './dto/update-message.dto';

type JwtPayload = {
  sub: string;
  email: string;
};

@Controller()
@UseGuards(JwtAuthGuard)
export class MessagesController {
  constructor(private readonly messagesService: MessagesService) {}

  @Post('channels/:channelId/messages')
  create(
    @CurrentUser() user: JwtPayload,
    @Param('channelId') channelId: string,
    @Body() dto: CreateMessageDto,
  ) {
    return this.messagesService.create(channelId, user.sub, dto);
  }

  @Get('channels/:channelId/messages')
  findByChannel(
    @CurrentUser() user: JwtPayload,
    @Param('channelId') channelId: string,
  ) {
    return this.messagesService.findByChannel(channelId, user.sub);
  }

  @Patch('messages/:messageId')
  update(
    @CurrentUser() user: JwtPayload,
    @Param('messageId') messageId: string,
    @Body() dto: UpdateMessageDto,
  ) {
    return this.messagesService.update(messageId, user.sub, dto);
  }

  @Delete('messages/:messageId')
  remove(
    @CurrentUser() user: JwtPayload,
    @Param('messageId') messageId: string,
  ) {
    return this.messagesService.remove(messageId, user.sub);
  }
}