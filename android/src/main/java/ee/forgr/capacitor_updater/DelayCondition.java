/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.util.Objects;

public class DelayCondition {

  private DelayUntilNext kind;
  private String value;

  public DelayCondition(DelayUntilNext kind, String value) {
    this.kind = kind;
    this.value = value;
  }

  public DelayUntilNext getKind() {
    return kind;
  }

  public void setKind(DelayUntilNext kind) {
    this.kind = kind;
  }

  public String getValue() {
    return value;
  }

  public void setValue(String value) {
    this.value = value;
  }

  @Override
  public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof DelayCondition)) return false;
    DelayCondition that = (DelayCondition) o;
    return (
      getKind() == that.getKind() && Objects.equals(getValue(), that.getValue())
    );
  }

  @Override
  public int hashCode() {
    return Objects.hash(getKind(), getValue());
  }

  @Override
  public String toString() {
    return (
      "DelayCondition{" + "kind=" + kind + ", value='" + value + '\'' + '}'
    );
  }
}
