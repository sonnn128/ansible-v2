#!/usr/bin/env bash
#
# setup-ssh-keys.sh
# Tự động tạo SSH key (nếu chưa có) và copy sang các server đích
# để Ansible chạy passwordless SSH.
#
# Usage:
#   ./setup-ssh-keys.sh
#   ./setup-ssh-keys.sh 192.168.1.101 192.168.1.200 192.168.1.88
#   SSH_USER=root ./setup-ssh-keys.sh
#
# Có thể sửa danh sách SERVERS bên dưới hoặc truyền IP qua tham số dòng lệnh.

set -uo pipefail

# ---------- Cấu hình ----------
SSH_USER="${SSH_USER:-root}"
KEY_TYPE="ed25519"
KEY_PATH="${HOME}/.ssh/id_${KEY_TYPE}"
SSH_PORT="${SSH_PORT:-22}"

# Danh sách server mặc định (dùng nếu không truyền tham số)
DEFAULT_SERVERS=(
    "192.168.1.101"   # loadbalancer-server
    "192.168.1.200"   # control-plane-1
    "192.168.1.88"    # control-plane-2
)

# Nếu có tham số dòng lệnh thì dùng tham số, không thì dùng danh sách mặc định
if [ "$#" -gt 0 ]; then
    SERVERS=("$@")
else
    SERVERS=("${DEFAULT_SERVERS[@]}")
fi

# ---------- Màu sắc cho output ----------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERR]${NC} $1"; }

# ---------- Bước 1: Kiểm tra / tạo SSH key ----------
echo "=== Bước 1: Kiểm tra SSH key ==="

if [ -f "${KEY_PATH}" ] && [ -f "${KEY_PATH}.pub" ]; then
    log_info "SSH key đã tồn tại tại ${KEY_PATH}, bỏ qua bước tạo mới."
else
    log_warn "Chưa có SSH key, đang tạo mới (${KEY_TYPE})..."
    if ssh-keygen -t "${KEY_TYPE}" -N "" -f "${KEY_PATH}" -q; then
        log_info "Tạo SSH key thành công: ${KEY_PATH}"
    else
        log_err "Tạo SSH key thất bại, dừng script."
        exit 1
    fi
fi

echo

# ---------- Bước 2: Kiểm tra công cụ cần thiết ----------
echo "=== Bước 2: Kiểm tra công cụ ==="

if command -v ssh-copy-id >/dev/null 2>&1; then
    HAS_SSH_COPY_ID=1
    log_info "Tìm thấy ssh-copy-id, sẽ dùng công cụ này."
else
    HAS_SSH_COPY_ID=0
    log_warn "Không tìm thấy ssh-copy-id, sẽ fallback dùng cat | ssh."
fi

echo

# ---------- Bước 3: Copy key sang từng server ----------
echo "=== Bước 3: Copy SSH key sang các server ==="

SUCCESS_LIST=()
FAIL_LIST=()

for HOST in "${SERVERS[@]}"; do
    echo "----------------------------------------"
    echo "-> Đang xử lý: ${SSH_USER}@${HOST}:${SSH_PORT}"

    # Kiểm tra host có ping/telnet được cổng SSH không (không bắt buộc thành công mới tiếp tục)
    if ! nc -z -w3 "${HOST}" "${SSH_PORT}" 2>/dev/null; then
        log_warn "Không kết nối được tới ${HOST}:${SSH_PORT} (có thể server tắt hoặc sai IP). Vẫn thử copy key..."
    fi

    if [ "${HAS_SSH_COPY_ID}" -eq 1 ]; then
        if ssh-copy-id -p "${SSH_PORT}" -i "${KEY_PATH}.pub" \
            -o StrictHostKeyChecking=accept-new \
            "${SSH_USER}@${HOST}"; then
            COPY_OK=1
        else
            COPY_OK=0
        fi
    else
        # Fallback thủ công nếu không có ssh-copy-id
        if cat "${KEY_PATH}.pub" | ssh -p "${SSH_PORT}" \
            -o StrictHostKeyChecking=accept-new \
            "${SSH_USER}@${HOST}" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
            COPY_OK=1
        else
            COPY_OK=0
        fi
    fi

    if [ "${COPY_OK}" -eq 1 ]; then
        log_info "Copy key thành công tới ${HOST}"
    else
        log_err "Copy key thất bại tới ${HOST}"
        FAIL_LIST+=("${HOST}")
        continue
    fi

    # ---------- Bước 4: Test lại bằng key, không dùng password ----------
    echo "   -> Kiểm tra đăng nhập bằng key (không dùng password)..."
    if ssh -p "${SSH_PORT}" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 \
        "${SSH_USER}@${HOST}" "echo ok" >/dev/null 2>&1; then
        log_info "Đăng nhập bằng key thành công tới ${HOST}"
        SUCCESS_LIST+=("${HOST}")
    else
        log_err "Đăng nhập bằng key THẤT BẠI tới ${HOST} (kiểm tra lại authorized_keys / permissions)"
        FAIL_LIST+=("${HOST}")
    fi
done

echo "----------------------------------------"
echo

# ---------- Tổng kết ----------
echo "=== Tổng kết ==="

if [ "${#SUCCESS_LIST[@]}" -gt 0 ]; then
    log_info "Thành công (${#SUCCESS_LIST[@]}/${#SERVERS[@]}):"
    for h in "${SUCCESS_LIST[@]}"; do
        echo "    - ${h}"
    done
else
    log_warn "Không có server nào setup key thành công."
fi

if [ "${#FAIL_LIST[@]}" -gt 0 ]; then
    log_err "Thất bại (${#FAIL_LIST[@]}/${#SERVERS[@]}):"
    for h in "${FAIL_LIST[@]}"; do
        echo "    - ${h}"
    done
    echo
    log_warn "Kiểm tra lại: đúng IP/port, user còn cho phép password login, firewall không chặn."
    exit 1
else
    echo
    log_info "Tất cả server đã sẵn sàng cho passwordless SSH. Có thể chạy: ansible all -i inventory.ini -m ping"
    exit 0
fi