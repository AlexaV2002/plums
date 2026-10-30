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
//   2) явно подтвердить её переменной TEST_DATABASE_URL, совпадающей с
//      DATABASE_URL. Оба условия обязательны.
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

let databaseName = '';
try {
  if (databaseUrl) {
    const parsed = new URL(databaseUrl);
    if (parsed.protocol === 'postgresql:' || parsed.protocol === 'postgres:') {
      databaseName = decodeURIComponent(parsed.pathname.slice(1));
    }
  }
} catch {
  // Invalid URL must never be accepted merely because credentials contain "test".
}

const looksLikeTestDatabase = /test/i.test(databaseName);
const explicitlyConfirmedAsTestDatabase =
  !!testDatabaseUrl && !!databaseUrl && testDatabaseUrl === databaseUrl;

if (!looksLikeTestDatabase || !explicitlyConfirmedAsTestDatabase) {
  throw new Error(
    'Отказ запускать e2e-тесты: DATABASE_URL должен указывать на отдельную ' +
      'PostgreSQL с "test" в имени базы, а TEST_DATABASE_URL должен точно ' +
      'совпадать с DATABASE_URL. e2e-тесты пишут и удаляют данные; рабочая ' +
      'или дев БД для них недопустима.',
  );
}
