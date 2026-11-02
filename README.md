# WattBar

macOS 選單列小工具，即時顯示 MacBook 目前的功耗、充電器輸出和電池狀態。

功能參考 [PowerTop](https://github.com/kDolphin/PowerTop)，用單一 Swift 檔重寫，只要 Xcode 命令列工具就能編譯，不需要完整的 Xcode。

## 功能

- 選單列顯示即時瓦數，電池補電或超過 99 W 時加上警示
- 充電器 → 系統 → 電池的電力流向圖
- 系統功耗、充電器輸出、電池充放電功率、充電器規格與負載率
- 電量、健康度、溫度、循環次數
- 充飽或用完的預估時間，會依 macOS 充電上限、AlDente、最佳化電池充電調整
- 詳細資訊視窗：充電狀態、各種容量、電芯結構（例如 2S2P）與平衡、生命週期統計、電池序號與製造日期

## 需求

- 有內建電池的 MacBook（Apple Silicon 才有完整功耗遙測，Intel 只有基本功能）
- macOS 13 以上
- Xcode 命令列工具：`xcode-select --install`

## 安裝

```
git clone https://github.com/yuxiang3002/WattBar.git
cd WattBar
bash build.sh
```

或直接雙擊 `安裝WattBar.command`。腳本會編譯、簽章、複製到「應用程式」並開啟。

自己編譯的 App 不會被 macOS 標成「從網路下載」，所以不會出現「已損毀，無法打開」。

如果是下載 Releases 裡編好的版本，第一次開啟前要在終端機執行：

```
xattr -cr /Applications/WattBar.app
```

## 授權

MIT。部分電池資料的讀取方式改寫自 PowerTop（MIT），詳見 LICENSE。
