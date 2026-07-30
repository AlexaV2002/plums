import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { PrismaModule } from '../prisma/prisma.module';
import { PermissionsModule } from '../permissions/permissions.module';
import { ServersController } from './servers.controller';
import { ServersService } from './servers.service';
import { ServersGateway } from './servers.gateway';

@Module({
  imports: [PrismaModule, JwtModule, PermissionsModule],
  controllers: [ServersController],
  providers: [ServersService, ServersGateway],
  exports: [ServersGateway],
})
export class ServersModule {}
