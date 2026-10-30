import { existsSync, readFileSync } from 'fs';
import { resolve } from 'path';

// Общий guard для всех e2e-спеков: не даёт прогону случайно стартовать
// AppModule (и тем самым Prisma) против рабочей/дев БД. Импортируй этот файл
// первой строкой в каждом *.e2e-spec.ts, до импорта AppModule — проверка
// бросает исключение синхронно при импорте, до того как ConfigModule
// прочитает .env и Prisma подключится к базе.
//
// Как включить реальный прогон e2e:
//   1) поднять отдельную тестовую БД (имя которой содержит "test",
//      например plums_test), и указать её в DATABASE_URL на время прогона;
//   2) либо явно подтвердить намерение переменной TEST_DATABASE_URL,
//      которая должна совпадать со значением DATABASE_URL, используемым
//      для подключения.
// process.env имеет приоритет над .env (как и у dotenv/ConfigModule).

function readEnvFileValue(key: string): string | undefined {
  const envPath = resolve(__dirname, '..', '.env');
  if (!existsSync(envPath)) {
    return undefined;
  }

  const content = readFileSync(envPath, 'utf8');
  const match = content.match(new RegExp(`^${key}\\s*=\\s*(.*)$`, 'm'));
  if (!match) {
    return undefined;
  }

  return match[1].trim().replace(/^['"]|['"]$/g, '');
}

function resolveValue(key: string): string | undefined {
  return process.env[key] ?? readEnvFileValue(key);
}

const databaseUrl = resolveValue('DATABASE_URL');
const testDatabaseUrl = resolveValue('TEST_DATABASE_URL');

const looksLikeTestDatabase = !!databaseUrl && /test/i.test(databaseUrl);
const explicitlyConfirmedAsTestDatabase =
  !!testDatabaseUrl && !!databaseUrl && testDatabaseUrl === databaseUrl;

if (!looksLikeTestDatabase && !explicitlyConfirmedAsTestDatabase) {
  throw new Error(
    'Отказ запускать e2e-тесты: DATABASE_URL не похож на выделенную ' +
      'тестовую БД (имя базы не содержит "test") и TEST_DATABASE_URL не ' +
      'подтверждает это явно. e2e-тесты пишут и удаляют данные — запускать ' +
      'их против рабочей/дев БД опасно. Укажи DATABASE_URL с тестовой базой ' +
      '(например ".../plums_test") и/или TEST_DATABASE_URL с тем же ' +
      'значением перед npm run test:e2e.',
  );
}
