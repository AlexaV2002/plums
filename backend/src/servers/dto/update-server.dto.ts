import { IsOptional, IsString, MaxLength, MinLength } from 'class-validator';

export class UpdateServerDto {
  @IsOptional()
  @IsString()
  @MinLength(2)
  @MaxLength(50)
  name?: string;

  @IsOptional()
  @IsString()
  iconUrl?: string;
}
