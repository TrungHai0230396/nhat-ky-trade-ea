# NhatKyTradeFeed — EA của Nhật Ký Trade cho MT4 và MT5

*[English below](#english)*

Đây là toàn bộ mã nguồn của EA mà [Nhật Ký Trade](https://nhatkytrade.com) dùng để nối với MetaTrader. Hai file trong repo này **giống hệt** file bạn tải ở **Cài đặt → Kết nối MT4/MT5** trong app. Chúng nằm ở đây để ai cũng đọc được trước khi cài, không cần tài khoản.

| File | Dùng cho | Phiên bản |
|---|---|---|
| `NhatKyTradeFeed.mq4` | MetaTrader 4 | 1.18 |
| `NhatKyTradeFeed.mq5` | MetaTrader 5 | 1.17 |

## EA gửi gì lên app

- Giá, nến và thông số hợp đồng của các mã
- Số dư, equity và loại tiền của tài khoản
- Số tài khoản và tên máy chủ sàn
- Lệnh đang mở và lệnh chờ
- Lệnh đã đóng, chỉ khi bạn bật *Tự ghi nhật ký* trong app

## EA không làm gì

- **Không đặt lệnh khi `AllowTrading = false`**, và đó là giá trị mặc định. Khi bạn tự bật lên, EA chỉ mở lệnh app gửi tới (bạn bấm ở trang Biểu đồ, hoặc bộ quy tắc của chính bạn khớp), không vượt `MaxLot` bạn đặt, và lệnh nào cũng phải kèm cắt lỗ.
- **Không sửa, không đóng lệnh nào.**
- **Không đọc mật khẩu, không rút tiền**: trong mã không có dòng nào làm việc đó.
- **Không dùng DLL**: để tắt ô *Allow DLL imports* thì EA vẫn chạy.
- **Chỉ gửi dữ liệu tới `https://nhatkytrade.com`**, không gửi đi đâu khác.

## Tự kiểm

1. Mở file bằng MetaEditor, hoặc bất kỳ trình soạn văn bản nào, và đọc.
2. Tìm `WebRequest(`: cả file chỉ có một chỗ gửi dữ liệu đi. Tìm `OrderSend(`: chỉ có một chỗ đặt lệnh, nằm sau mọi điều kiện kiểm tra.
3. Tự bấm Compile. App không phát file `.ex4` hay `.ex5` đã biên dịch sẵn.
4. Muốn chắc hơn thì chạy thử trên tài khoản demo trước.

## Cài đặt

Hướng dẫn 5 bước, mỗi bước kèm hình, nằm ở **Cài đặt → Kết nối MT4/MT5** trong app. EA cần một mã kết nối tạo ở đó; mã không nằm trong file này.

## Giấy phép

[MIT](LICENSE).

---

<a id="english"></a>

# NhatKyTradeFeed — the Nhật Ký Trade EA for MT4 and MT5

This is the complete source of the EA that [Nhật Ký Trade](https://nhatkytrade.com) uses to connect to MetaTrader. The two files here are **identical** to the ones you download from **Settings → MT4/MT5 connection** in the app. They are here so that anyone can read them before installing, with no account.

| File | For | Version |
|---|---|---|
| `NhatKyTradeFeed.mq4` | MetaTrader 4 | 1.18 |
| `NhatKyTradeFeed.mq5` | MetaTrader 5 | 1.17 |

## What the EA sends to the app

- Prices, candles and contract terms of the symbols
- The account's balance, equity and currency
- The account number and the broker's server name
- Open positions and pending orders
- Closed trades, only while *Auto-journal* is on in the app

## What the EA never does

- **It places no order while `AllowTrading = false`**, which is the default. Once you turn that on yourself, it only opens orders the app sends (one you clicked on the Chart page, or one your own rule set matched), never above the `MaxLot` you set, and never without a stop loss.
- **It never modifies or closes an order.**
- **It does not read your password or withdraw money**: no line of its code does either.
- **It uses no DLL**: it runs with *Allow DLL imports* unticked.
- **It sends data only to `https://nhatkytrade.com`**, and nowhere else.

## Check it yourself

1. Open the file in MetaEditor, or any text editor, and read it.
2. Search for `WebRequest(`: the whole file sends data from one place. Search for `OrderSend(`: it places orders from one place, after every check.
3. Press Compile yourself. The app hands out no compiled `.ex4` or `.ex5` file.
4. To be surer still, run it on a demo account first.

## Installing

The five steps, each with a drawing, are under **Settings → MT4/MT5 connection** in the app. The EA needs a connection token created there; the token is not in these files.

## Licence

[MIT](LICENSE).
