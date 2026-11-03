// Match the native app's nine supported languages. Account text is intentionally
// small; provider errors and private request details are never rendered.
export const strings = {
  en: { lang: 'en', apple: 'en_US', signIn: 'Sign in to Carry', account: 'Your Carry account',
    intro: 'Keep your trips close, wherever you plan.', appleLabel: 'Sign in with Apple',
    signOut: 'Sign out', privacy: 'Privacy', unavailable: 'We couldn’t complete that just now.',
    retry: 'Return to sign in', cancelled: 'Sign-in cancelled. You can try again whenever you’re ready.' },
  'zh-Hans': { lang: 'zh-Hans', apple: 'zh_CN', signIn: '登录启程', account: '你的启程账户',
    intro: '让每一次出发更从容。', appleLabel: '通过 Apple 登录',
    signOut: '退出登录', privacy: '隐私政策', unavailable: '暂时未能完成，请稍后再试。',
    retry: '返回登录', cancelled: '已取消登录。准备好后可以再试。' },
  'zh-Hant': { lang: 'zh-Hant', apple: 'zh_TW', signIn: '登入啟程', account: '你的啟程帳號',
    intro: '讓每一次出發更從容。', appleLabel: '透過 Apple 登入',
    signOut: '登出', privacy: '隱私權政策', unavailable: '暫時無法完成，請稍後再試。',
    retry: '返回登入', cancelled: '已取消登入。準備好後可以再試。' },
  de: { lang: 'de', apple: 'de_DE', signIn: 'Bei Carry anmelden', account: 'Dein Carry-Konto',
    intro: 'Deine Reisen immer dabei, egal wo du planst.', appleLabel: 'Mit Apple anmelden',
    signOut: 'Abmelden', privacy: 'Datenschutz', unavailable: 'Das hat gerade nicht geklappt. Bitte versuche es später erneut.',
    retry: 'Zurück zur Anmeldung', cancelled: 'Anmeldung abgebrochen. Du kannst es jederzeit erneut versuchen.' },
  es: { lang: 'es', apple: 'es_ES', signIn: 'Inicia sesión en Carry', account: 'Tu cuenta de Carry',
    intro: 'Tus viajes siempre cerca, planifiques donde planifiques.', appleLabel: 'Iniciar sesión con Apple',
    signOut: 'Cerrar sesión', privacy: 'Privacidad', unavailable: 'No hemos podido completar la acción. Inténtalo más tarde.',
    retry: 'Volver al inicio de sesión', cancelled: 'Inicio de sesión cancelado. Puedes intentarlo de nuevo cuando quieras.' },
  fr: { lang: 'fr', apple: 'fr_FR', signIn: 'Se connecter à Carry', account: 'Votre compte Carry',
    intro: 'Vos voyages à portée de main, où que vous les prépariez.', appleLabel: 'Se connecter avec Apple',
    signOut: 'Se déconnecter', privacy: 'Confidentialité', unavailable: 'Cette action n’a pas pu aboutir. Réessayez plus tard.',
    retry: 'Revenir à la connexion', cancelled: 'Connexion annulée. Vous pouvez réessayer quand vous le souhaitez.' },
  ja: { lang: 'ja', apple: 'ja_JP', signIn: 'Carryにログイン', account: 'Carryアカウント',
    intro: 'どこで計画しても、旅の準備をいつもそばに。', appleLabel: 'Appleでサインイン',
    signOut: 'ログアウト', privacy: 'プライバシー', unavailable: '処理を完了できませんでした。しばらくしてからお試しください。',
    retry: 'ログインに戻る', cancelled: 'ログインをキャンセルしました。準備ができたら再度お試しください。' },
  ko: { lang: 'ko', apple: 'ko_KR', signIn: 'Carry 로그인', account: '내 Carry 계정',
    intro: '어디서 계획하든, 여행 준비를 늘 가까이에.', appleLabel: 'Apple로 로그인',
    signOut: '로그아웃', privacy: '개인정보 처리방침', unavailable: '지금은 완료할 수 없습니다. 잠시 후 다시 시도해 주세요.',
    retry: '로그인으로 돌아가기', cancelled: '로그인이 취소되었습니다. 준비되면 다시 시도해 주세요.' },
  'pt-BR': { lang: 'pt-BR', apple: 'pt_BR', signIn: 'Entrar no Carry', account: 'Sua conta Carry',
    intro: 'Suas viagens por perto, onde quer que você planeje.', appleLabel: 'Iniciar sessão com a Apple',
    signOut: 'Sair', privacy: 'Privacidade', unavailable: 'Não foi possível concluir agora. Tente novamente mais tarde.',
    retry: 'Voltar para entrar', cancelled: 'Login cancelado. Você pode tentar novamente quando quiser.' },
};
export function language(header) {
  const candidates = String(header ?? '').split(',').slice(0, 20).map((entry, index) => {
    const [tag, ...params] = entry.trim().split(';');
    const q = params.find(value => value.trim().startsWith('q='));
    return { tag: tag.toLowerCase(), weight: q ? Number(q.trim().slice(2)) : 1, index };
  }).filter(value => Number.isFinite(value.weight) && value.weight > 0 && value.weight <= 1)
    .sort((a, b) => b.weight - a.weight || a.index - b.index);
  for (const { tag } of candidates) {
    if (/^zh(?:-|$)/.test(tag)) return /(?:hant|tw|hk|mo)/.test(tag) ? 'zh-Hant' : 'zh-Hans';
    if (/^pt(?:-|$)/.test(tag)) return 'pt-BR';
    const base = tag.split('-')[0];
    if (Object.hasOwn(strings, base)) return base;
  }
  return 'en';
}
