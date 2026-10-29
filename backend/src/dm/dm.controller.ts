import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { CreateDmConversationDto } from './dto/create-dm-conversation.dto';
import { GetDmMessagesQueryDto } from './dto/get-dm-messages-query.dto';
import { SendDmMessageDto } from './dto/send-dm-message.dto';
import { DmService } from './dm.service';

type JwtPayload = {
  sub: string;
  email: string;
};

@Controller()
@UseGuards(JwtAuthGuard)
export class DmController {
  constructor(private readonly dmService: DmService) {}

  @Get('dm/conversations')
  findConversations(@CurrentUser() user: JwtPayload) {
    return this.dmService.findConversations(user.sub);
  }

  @Post('dm/conversations')
  getOrCreateConversation(
    @CurrentUser() user: JwtPayload,
    @Body() dto: CreateDmConversationDto,
  ) {
    return this.dmService.getOrCreateConversation(user.sub, dto);
  }

  @Get('dm/conversations/:conversationId/messages')
  findMessages(
    @CurrentUser() user: JwtPayload,
    @Param('conversationId') conversationId: string,
    @Query() query: GetDmMessagesQueryDto,
  ) {
    return this.dmService.findMessages(conversationId, user.sub, query);
  }

  @Post('dm/conversations/:conversationId/messages')
  sendMessage(
    @CurrentUser() user: JwtPayload,
    @Param('conversationId') conversationId: string,
    @Body() dto: SendDmMessageDto,
  ) {
    return this.dmService.sendMessage(conversationId, user.sub, dto);
  }

  @Delete('dm/messages/:messageId')
  @HttpCode(204)
  removeMessage(
    @CurrentUser() user: JwtPayload,
    @Param('messageId') messageId: string,
  ) {
    return this.dmService.removeMessage(messageId, user.sub);
  }
}
