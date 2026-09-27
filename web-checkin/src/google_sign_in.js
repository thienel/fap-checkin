import { GoogleAuthProvider, signInWithPopup } from 'firebase/auth';

export function googleSignInError(error) {
  switch (error?.code) {
    case 'auth/popup-blocked':
    case 'auth/operation-not-supported-in-this-environment':
    case 'auth/missing-initial-state':
      return 'Trình duyệt đã chặn cửa sổ đăng nhập Google. Hãy mở liên kết này bằng Chrome hoặc Safari rồi thử lại.';
    case 'auth/popup-closed-by-user':
    case 'auth/cancelled-popup-request':
      return 'Cửa sổ đăng nhập Google đã đóng. Hãy nhấn đăng nhập để thử lại.';
    case 'auth/unauthorized-domain':
      return 'Địa chỉ trang này chưa được cho phép đăng nhập Google. Hãy liên hệ giảng viên.';
    case 'auth/network-request-failed':
      return 'Không kết nối được Google. Hãy kiểm tra mạng rồi thử lại.';
    default:
      return 'Không thể đăng nhập Google. Hãy thử lại hoặc mở liên kết bằng Chrome hoặc Safari.';
  }
}

export function signInWithGoogle(auth) {
  const provider = new GoogleAuthProvider();
  provider.setCustomParameters({ prompt: 'select_account' });
  return signInWithPopup(auth, provider);
}
