//
// moderation-notifier
//
// reports / blocks コレクションの notified == false のドキュメントを検出し、
// 開発者（cjie46251@gmail.com）へメール通知する。
// 送信成功後、Admin SDK（セキュリティルール対象外）で notified: true / notifiedAt を更新する。
//
// 実行環境: GitHub Actions（.github/workflows/moderation-notifier.yml）
// 必要な環境変数:
//   FIREBASE_SERVICE_ACCOUNT_JSON : Firebase サービスアカウントの JSON 文字列
//   SMTP_HOST / SMTP_PORT / SMTP_SECURE / SMTP_USER / SMTP_PASS : SMTP 認証情報
//   SMTP_FROM (任意)                                            : 送信元アドレス（未設定時は SMTP_USER）
//   NOTIFY_EMAIL (任意)                                         : 通知先アドレス（未設定時は既定のcjie46251@gmail.com）
//

const admin = require('firebase-admin');
const nodemailer = require('nodemailer');

const DEFAULT_NOTIFY_EMAIL = 'cjie46251@gmail.com';

const REPORT_REASON_LABELS = {
  inappropriateContent: '不適切なコンテンツ（性的・暴力的など）',
  harassment: '嫌がらせ・いじめ',
  spam: 'スパム',
  impersonation: 'なりすまし',
  other: 'その他',
};

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`環境変数 ${name} が設定されていません`);
  }
  return value;
}

function initFirebaseAdmin() {
  const serviceAccountJson = requireEnv('FIREBASE_SERVICE_ACCOUNT_JSON');
  const serviceAccount = JSON.parse(serviceAccountJson);

  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });

  return {
    db: admin.firestore(),
    projectId: serviceAccount.project_id,
  };
}

function consoleLink(projectId, collection, docId) {
  return `https://console.firebase.google.com/project/${projectId}/firestore/data/~2F${collection}~2F${docId}`;
}

async function fetchUnnotified(db, collectionName) {
  const snapshot = await db.collection(collectionName).where('notified', '==', false).get();
  return snapshot.docs;
}

function buildReportSection(docs, projectId) {
  if (docs.length === 0) {
    return '';
  }

  const items = docs
    .map((doc) => {
      const data = doc.data();
      const reasonLabel = REPORT_REASON_LABELS[data.reason] || data.reason;

      return [
        `- reportId: ${doc.id}`,
        `  対象種別: ${data.targetType}`,
        `  対象ユーザーID: ${data.targetUserId}`,
        data.targetPostId ? `  対象投稿ID: ${data.targetPostId}` : null,
        `  理由: ${reasonLabel}`,
        data.detail ? `  詳細: ${data.detail}` : null,
        `  通報者ID: ${data.reporterId}`,
        `  コンソール: ${consoleLink(projectId, 'reports', doc.id)}`,
      ]
        .filter(Boolean)
        .join('\n');
    })
    .join('\n\n');

  return `\n【新規の通報 (${docs.length}件)】\n${items}\n`;
}

function buildBlockSection(docs, projectId) {
  if (docs.length === 0) {
    return '';
  }

  const items = docs
    .map((doc) => {
      const data = doc.data();

      return [
        `- blockId: ${doc.id}`,
        `  ブロックした人: ${data.blockerId}`,
        `  ブロックされた人: ${data.blockedId}`,
        `  コンソール: ${consoleLink(projectId, 'blocks', doc.id)}`,
      ].join('\n');
    })
    .join('\n\n');

  return `\n【新規のブロック (${docs.length}件)】\n${items}\n`;
}

async function markNotified(db, docs) {
  if (docs.length === 0) {
    return;
  }

  const batch = db.batch();
  const now = admin.firestore.FieldValue.serverTimestamp();

  docs.forEach((doc) => {
    batch.update(doc.ref, { notified: true, notifiedAt: now });
  });

  await batch.commit();
}

async function sendNotificationEmail(body) {
  const notifyEmail = process.env.NOTIFY_EMAIL || DEFAULT_NOTIFY_EMAIL;

  const transporter = nodemailer.createTransport({
    host: requireEnv('SMTP_HOST'),
    port: Number(process.env.SMTP_PORT || 587),
    secure: process.env.SMTP_SECURE === 'true',
    auth: {
      user: requireEnv('SMTP_USER'),
      pass: requireEnv('SMTP_PASS'),
    },
  });

  await transporter.sendMail({
    from: process.env.SMTP_FROM || process.env.SMTP_USER,
    to: notifyEmail,
    subject: 'Peephole: 未対応の通報・ブロックがあります',
    text: body,
  });
}

async function main() {
  const { db, projectId } = initFirebaseAdmin();

  const reportDocs = await fetchUnnotified(db, 'reports');
  const blockDocs = await fetchUnnotified(db, 'blocks');

  if (reportDocs.length === 0 && blockDocs.length === 0) {
    console.log('未通知の reports / blocks はありません。メール送信をスキップします。');
    return;
  }

  const body = [
    'Peephole: 未対応の通報・ブロックが検出されました。',
    '24時間以内に Firebase コンソールで内容を確認し、対応してください。',
    buildReportSection(reportDocs, projectId),
    buildBlockSection(blockDocs, projectId),
  ]
    .filter(Boolean)
    .join('\n');

  await sendNotificationEmail(body);
  console.log(`通知メールを送信しました（reports: ${reportDocs.length}件, blocks: ${blockDocs.length}件）。`);

  await markNotified(db, reportDocs);
  await markNotified(db, blockDocs);
  console.log('notified フラグを更新しました。');
}

main().catch((error) => {
  console.error('モデレーション通知処理でエラーが発生しました:', error);
  process.exitCode = 1;
});
