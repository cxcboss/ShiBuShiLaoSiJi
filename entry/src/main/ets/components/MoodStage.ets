/**
 * 检测中的"乘客状态台"：呼吸光环 + 表情 + 一句话。
 * 这里不出现加速度、等级、RMS 等任何专业数值，检测中的反馈只说人话，
 * 具体数字在结束后的行程报告里看。
 */
@ComponentV2
export struct MoodStage {
  @Param emoji: string = '🙂';
  @Param title: string = '';
  @Param hint: string = '';
  @Param color: string = '#00C853';
  /** 每有新事件自增，弹一次表情；0 表示尚无事件，不弹 */
  @Param pulseKey: number = 0;

  @Local breath: number = 0.5;
  @Local bounce: number = 1;
  /** 呼吸动画定时器句柄：卸载必须 clear，否则动画链会一直挂起并持有组件引用 */
  private breathTimer: number = -1;
  /** 弹跳复位定时器句柄 */
  private bounceTimer: number = -1;
  /** 动画开关用 0/1 交替而非 breath 自身比较，避免动画被打断后停在中间值卡死 */
  private breathPhase: number = 0;

  aboutToAppear(): void {
    // 先清掉可能存在的旧链，防止重复挂载时两条动画链叠加
    if (this.breathTimer >= 0) {
      clearTimeout(this.breathTimer);
      this.breathTimer = -1;
    }
    const animate = (): void => {
      this.getUIContext().animateTo({ duration: 1400, curve: Curve.EaseInOut }, () => {
        this.breathPhase ^= 1;
        this.breath = this.breathPhase === 1 ? 1 : 0.5;
      });
      this.breathTimer = setTimeout((): void => {
        this.breathTimer = -1;
        animate();
      }, 1450);
    };
    animate();
  }

  aboutToDisappear(): void {
    if (this.breathTimer >= 0) {
      clearTimeout(this.breathTimer);
      this.breathTimer = -1;
    }
    if (this.bounceTimer >= 0) {
      clearTimeout(this.bounceTimer);
      this.bounceTimer = -1;
    }
  }

  /** 新事件弹一下：涨 22% 再回落，让界面"有反应"但不打扰 */
  @Monitor('pulseKey')
  onPulse(): void {
    if (this.bounceTimer >= 0) {
      clearTimeout(this.bounceTimer);
    }
    this.getUIContext().animateTo({ duration: 150, curve: Curve.Sharp }, () => {
      this.bounce = 1.22;
    });
    this.bounceTimer = setTimeout((): void => {
      this.bounceTimer = -1;
      this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseOut }, () => {
        this.bounce = 1;
      });
    }, 160);
  }

  build() {
    Column({ space: 14 }) {
      Stack({ alignContent: Alignment.Center }) {
        Progress({ value: 100, total: 100, type: ProgressType.Ring })
          .width(220)
          .height(220)
          .color(this.color)
          .backgroundColor($r('app.color.track_bg'))
          .style({ strokeWidth: 14 })
          .opacity(0.3 + this.breath * 0.7)
          // 纯装饰环：不关掉的话读屏会念出 "100.000000"，反而成了界面上残留的数字
          .accessibilityLevel('no')
        Text(this.emoji)
          .fontSize(78)
          .scale({ x: this.bounce, y: this.bounce })
      }

      Column({ space: 6 }) {
        Text(this.title)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.font_primary'))
          .textAlign(TextAlign.Center)
        Text(this.hint)
          .fontSize(16)
          .fontColor($r('app.color.font_tertiary'))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
