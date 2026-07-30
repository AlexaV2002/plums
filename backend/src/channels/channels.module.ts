import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { PrismaModule } from '../prisma/prisma.module';
import { PermissionsModule } from '../permissions/permissions.module';
import { ChannelsController } from './channels.controller';
import { ChannelsGateway } from './channels.gateway';
import { ChannelsService } from './channels.service';

@Module({
  imports: [PrismaModule, JwtModule, PermissionsModule],
  controllers: [ChannelsController],
  providers: [ChannelsService, ChannelsGateway],
})
export class ChannelsModule {}
