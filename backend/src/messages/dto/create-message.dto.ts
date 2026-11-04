import {
  IsOptional,
  IsString,
  IsUUID,
  IsArray,
  ArrayMaxSize,
  ArrayUnique,
  MaxLength,
} from 'class-validator';

export class CreateMessageDto {
  @IsString()
  @MaxLength(2000)
  content!: string;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(4)
  @ArrayUnique()
  @IsUUID('4', { each: true })
  attachmentIds?: string[];

  @IsOptional()
  @IsUUID('4')
  clientMessageId?: string;
}
