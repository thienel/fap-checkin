export function signInBrowserProblem(userAgent, getSessionStorage) {
  if (/Zalo|FBAN|FBAV|FB_IAB|Instagram|Messenger|;\s*wv\)/i.test(userAgent)) {
    return 'embedded';
  }
  try {
    const storage = getSessionStorage();
    const key = 'attendanceAuthStorageProbe';
    storage.setItem(key, '1');
    const readable = storage.getItem(key) === '1';
    storage.removeItem(key);
    if (!readable) return 'storage';
  } catch (_) {
    return 'storage';
  }
  return null;
}
