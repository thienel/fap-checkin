export function duplicatePresentation(attendanceStatus, email) {
  if (attendanceStatus === 'absent') {
    return {
      kind: 'warning',
      title: 'Bạn đang được ghi nhận vắng',
      detail: `${email} đang được ghi nhận vắng cho buổi này. Hãy liên hệ giảng viên nếu cần điều chỉnh.`,
    };
  }
  if (attendanceStatus === 'excused') {
    return {
      kind: 'info',
      title: 'Bạn đang được ghi nhận có phép',
      detail: `${email} đang được ghi nhận có phép cho buổi này.`,
    };
  }
  return {
    kind: 'success',
    title: 'Đã điểm danh trước đó',
    detail: `${email} đã được ghi nhận có mặt cho buổi này.`,
  };
}
