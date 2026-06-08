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
import { CreateServerDto } from './dto/create-server.dto';
import { UpdateServerDto } from './dto/update-server.dto';
import { ServersService } from './servers.service';

type JwtPayload = {
  sub: string;
  email: string;
};

@UseGuards(JwtAuthGuard)
@Controller('servers')
export class ServersController {
  constructor(private readonly serversService: ServersService) {}

  @Post()
  createServer(@CurrentUser() user: JwtPayload, @Body() dto: CreateServerDto) {
    return this.serversService.createServer(user.sub, dto);
  }

  @Get()
  getMyServers(@CurrentUser() user: JwtPayload) {
    return this.serversService.getMyServers(user.sub);
  }

  @Get(':id')
  getServerById(@CurrentUser() user: JwtPayload, @Param('id') id: string) {
    return this.serversService.getServerById(user.sub, id);
  }

  @Get(':id/members')
  getServerMembers(@CurrentUser() user: JwtPayload, @Param('id') id: string) {
    return this.serversService.getServerMembers(user.sub, id);
  }

  @Patch(':id')
  updateServer(
    @CurrentUser() user: JwtPayload,
    @Param('id') id: string,
    @Body() dto: UpdateServerDto,
  ) {
    return this.serversService.updateServer(user.sub, id, dto);
  }

  @Delete(':id')
  deleteServer(@CurrentUser() user: JwtPayload, @Param('id') id: string) {
    return this.serversService.deleteServer(user.sub, id);
  }

  @Delete(':id/members/me')
  leaveServer(@CurrentUser() user: JwtPayload, @Param('id') id: string) {
    return this.serversService.leaveServer(user.sub, id);
  }

  @Delete(':id/members/:memberId')
  kickServerMember(
    @CurrentUser() user: JwtPayload,
    @Param('id') id: string,
    @Param('memberId') memberId: string,
  ) {
    return this.serversService.kickServerMember(user.sub, id, memberId);
  }
}
