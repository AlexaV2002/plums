import { IsEnum, IsOptional, IsString, MaxLength, MinLength } from 'class-validator';

enum ChannelType {
  TEXT = 'TEXT',
  VOICE = 'VOICE',
}

export class CreateChannelDto {
  @IsString()
  @MinLength(2)
  @MaxLength(50)
  name!: string;

  @IsOptional()
  @IsEnum(ChannelType)
  type?: ChannelType;
}