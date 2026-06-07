import { Body, Controller, Get, Param, Post, UseGuards } from '@nestjs/common';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { CreateServerDto } from './dto/create-server.dto';
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
}
