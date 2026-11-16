<!-- read as: html -->
*Not to be confused with* [*quadratic function*](https://en.wikipedia.org/wiki/Quadratic_function) *or* [*quadratic equation*](https://en.wikipedia.org/wiki/Quadratic_equation)*.*

⟦picture 1⟧

The roots of the quadratic function *y* =

1

2

*x*² − 3*x* +

5

2

are the places where the graph intersects the *x*-axis, the values *x* = 1 and *x* = 5. They can be found via the quadratic formula.

In [elementary algebra](https://en.wikipedia.org/wiki/Elementary_algebra), the **quadratic formula** is a [closed-form expression](https://en.wikipedia.org/wiki/Closed-form_expression) describing the solutions of a [quadratic equation](https://en.wikipedia.org/wiki/Quadratic_equation). Other ways of solving quadratic equations, such as [completing the square](https://en.wikipedia.org/wiki/Completing_the_square), yield the same solutions.

Given a general quadratic equation of the form $ax^2 + bx + c = 0$, with $x$ representing an unknown, and [coefficients $a$](https://en.wikipedia.org/wiki/Coefficient), $b$, and $c$ representing known [real](https://en.wikipedia.org/wiki/Real_number) or [complex](https://en.wikipedia.org/wiki/Complex_number) numbers with $a \neq 0$, the values of $x$ satisfying the equation, called the [*roots*](https://en.wikipedia.org/wiki/Zero_of_a_function) or *zeros*, can be found using the quadratic formula,

$$x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a},$$

where the [plus–minus symbol](https://en.wikipedia.org/wiki/Plus%E2%80%93minus_sign) "$\pm$" indicates that the equation has two roots. Written separately, these are:

$$
x_1 = \frac{-b + \sqrt {b^2 - 4ac}}{2a}, \qquad
x_2 = \frac{-b - \sqrt {b^2 - 4ac}}{2a}.
$$

The quantity $\Delta = b^2 - 4ac$ is known as the [discriminant](https://en.wikipedia.org/wiki/Discriminant) of the quadratic equation. If the coefficients $a$, $b$, and $c$ are real numbers then when $\Delta > 0$, the equation has two distinct real roots; when $\Delta = 0$, the equation has one [repeated](https://en.wikipedia.org/wiki/Repeated_root) real root; and when $\Delta < 0$, the equation has *no* real roots but has two distinct complex roots, which are [complex conjugates](https://en.wikipedia.org/wiki/Complex_conjugate) of each other.

Geometrically, the roots represent the $x$ values at which the [graph](https://en.wikipedia.org/wiki/Graph_of_a_function) of the [quadratic function $y = ax^2 + bx + c$](https://en.wikipedia.org/wiki/Quadratic_function), a [parabola](https://en.wikipedia.org/wiki/Parabola), crosses the $x$-axis: the graph's $x$-intercepts. The quadratic formula can also be used to identify the parabola's [axis of symmetry](https://en.wikipedia.org/wiki/Axis_of_symmetry).

## Derivation by completing the square

⟦picture 2⟧

To complete the square, form a squared binomial on the left-hand side of a quadratic equation, from which the solution can be found by taking the square root of both sides.

The standard way to derive the quadratic formula is to apply the method of [completing the square](https://en.wikipedia.org/wiki/Completing_the_square) to the generic quadratic equation $ax^2 + bx + c = 0$. The idea is to transform the equation into the form $(x + k)^2 = s$ for some expressions $k$ and $s$ written in terms of the coefficients; take the [square root](https://en.wikipedia.org/wiki/Square_root) of both sides; and then isolate $x$.

We start by dividing the equation by the quadratic coefficient $a$, which is allowed because $a$ is non-zero. Afterwards, we subtract the constant term $c/a$ to isolate it on the right-hand side:

$$
\begin{align}
ax^{2\vphantom|} + bx + c &= 0 \\[3mu]
x^2 + \frac{b}{a} x + \frac{c}{a} &= 0 \\[3mu]
x^2 + \frac{b}{a} x &= -\frac{c}{a}.
\end{align}
$$

The left-hand side is now of the form $x^2 + 2kx$, and we can "complete the square" by adding a constant $k^2$ to obtain a squared binomial $x^2 + 2kx + k^2 = {}$$(x + k)^2$. In this example we add $(b / 2a)^2$ to both sides so that the left-hand side can be factored (see the figure):

$$
\begin{align}
x^2 + 2\left(\frac{b}{2a}\right)x + \left(\frac{b}{2a}\right)^2
&= -\frac{c}{a}+\left( \frac{b}{2a} \right)^2 \\[5mu]
\left(x + \frac{b}{2a}\right)^2
&= \frac{b^2 - 4ac}{4a^2} .
\end{align}
$$

Because the left-hand side is now a perfect square, we can easily take the square root of both sides:

$$x + \frac{b}{2a} = \pm\frac{\sqrt{b^2 - 4ac}}{2a}.$$

Finally, subtracting $b/2a$ from both sides to isolate $x$ produces the quadratic formula:

$$x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a} .$$

## Equivalent formulations

The quadratic formula can equivalently be written using various alternative expressions, for instance

$$x = -\frac{b}{2a} \pm \sqrt{\left(\frac{b}{2a}\right)^2-\frac{c}{a}},$$

which can be derived by first dividing a quadratic equation by $2a$, resulting in $\tfrac12 x^2 + \tfrac{b}{2a}x + \tfrac{c}{2a} = 0$, then substituting the new coefficients into the standard quadratic formula. Because this variant allows re-use of the intermediately calculated quantity $\tfrac{b}{2a}$, it can slightly reduce the arithmetic involved.

### Square root in the denominator

A lesser known quadratic formula, first mentioned by [Giulio Fagnano](https://en.wikipedia.org/wiki/Giulio_Carlo_de'_Toschi_di_Fagnano), describes the same roots via an equation with the square root in the denominator (assuming $c \neq 0$):

$$x= \frac{2c}{-b \mp \sqrt {b^2 - 4ac}}.$$

Here the [minus–plus symbol](https://en.wikipedia.org/wiki/Minus%E2%80%93plus_symbol) "$\mp$" indicates that the two roots of the quadratic equation, in the same order as the standard quadratic formula, are

$$
x_1 = \frac{2c}{-b - \sqrt {b^2 - 4ac}}, \qquad
x_2 = \frac{2c}{-b + \sqrt {b^2 - 4ac}}.
$$

This variant has been jokingly called the "citardauq" formula ("quadratic" spelled backwards).

When $-b$ has the opposite sign as either $+\sqrt {b^2 - 4ac}$ or $-\sqrt {b^2 - 4ac}$, subtraction can cause [catastrophic cancellation](https://en.wikipedia.org/wiki/Catastrophic_cancellation), resulting in poor accuracy in numerical calculations; choosing between the version of the quadratic formula with the square root in the numerator or denominator depending on the sign of $b$ can avoid this problem. See [§ Numerical calculation](https://en.wikipedia.org/wiki/Quadratic_formula#Numerical_calculation) below.

This version of the quadratic formula is used in [Muller's method](https://en.wikipedia.org/wiki/Muller's_method) for finding the roots of general functions. It can be derived from the standard formula from the identity $x_1 x_2 = c/a$, one of [Vieta's formulas](https://en.wikipedia.org/wiki/Vieta's_formulas). Alternately, it can be derived by dividing each side of the equation $ax^2 + bx + c = 0$ by $x^2$ to get $cx^{-2} + bx^{-1} + a = 0$, applying the standard formula to find the two roots $x^{-1}\!$, and then taking the reciprocal to find the roots $x$ of the original equation.

## Other derivations

Any generic method or algorithm for solving quadratic equations can be applied to an equation with symbolic coefficients and used to derive some closed-form expression equivalent to the quadratic formula. Alternative methods are sometimes simpler than completing the square, and may offer interesting insight into other areas of mathematics.

### Completing the square by Śrīdhara's method

Instead of dividing by $a$ to isolate $x^2\!$, it can be slightly simpler to multiply by $4a$ instead to produce $(2ax)^2\!$, which allows us to complete the square without need for fractions. Then the steps of the derivation are:

1. Multiply each side by $4a$.
2. Add $b^2 - 4ac$ to both sides to complete the square.
3. Take the square root of both sides.
4. Isolate $x$.

Applying this method to a generic quadratic equation with symbolic coefficients yields the quadratic formula:

$$
\begin{align}
ax^2 + bx + c &= 0 \\[3mu]
4 a^2 x^2 + 4abx + 4ac &= 0 \\[3mu]
4 a^2 x^2 + 4abx + b^2 &= b^2 - 4ac \\[3mu]
(2ax + b)^2 &= b^2 - 4ac \\[3mu]
2ax + b &= \pm \sqrt{b^2 - 4ac} \\[5mu]
x &= \dfrac{-b\pm\sqrt{b^2 - 4ac }}{2a}. \vphantom\bigg)
\end{align}
$$

This method for completing the square is ancient and was known to the 8th–9th century Indian mathematician [Śrīdhara](https://en.wikipedia.org/wiki/%C5%9Ar%C4%ABdhara). Compared with the modern standard method for completing the square, this alternate method avoids fractions until the last step and hence does not require a rearrangement after step 3 to obtain a common denominator in the right side.

### By substitution

Another derivation uses a [change of variables](https://en.wikipedia.org/wiki/Change_of_variables) to eliminate the linear term. Then the equation takes the form $u^2 = s$ in terms of a new variable $u$ and some constant expression $s$, whose roots are then $u = \pm \sqrt s$.

By substituting $x = u - \tfrac{b}{2a}$ into $ax^2 + bx + c = 0$, expanding the products and combining [like terms](https://en.wikipedia.org/wiki/Like_terms), and then solving for $u^2\!$, we have:

$$
\begin{align}
a\left(u-\frac{b}{2a}\right)^2 + b\left(u-\frac{b}{2a}\right) + c &=0 \\[5mu]
a\left(u^2-\frac{b}{a}u+\frac{b^2}{4a^2}\right) + b\left(u-\frac{b}{2a}\right) + c &= 0 \\[5mu]
au^2 - bu + \frac{b^2}{4a} + bu - \frac{b^2}{2a}+c &= 0 \\[5mu]
au^2 + \frac{4ac - b^2}{4a} &= 0 \\[5mu]
u^2 &= \frac{b^2 - 4ac}{4a^2}.
\end{align}
$$

Finally, after taking a square root of both sides and substituting the resulting expression for $u$ back into $x = u - \tfrac{b}{2a},$ the familiar quadratic formula emerges:

$$x = \frac{-b\pm \sqrt{b^2 - 4ac}}{2a}.$$

### By using algebraic identities

The following method was used by many historical mathematicians:

Let the roots of the quadratic equation $ax^2 + bx + c = 0$ be $\alpha$ and $\beta$. The derivation starts from an identity for the square of a difference (valid for any two complex numbers), of which we can take the square root on both sides:

$$
\begin{align}
(\alpha - \beta)^2 &= (\alpha + \beta)^2 - 4 \alpha\beta \\[3mu]
\alpha - \beta &= \pm\sqrt{(\alpha + \beta)^2 - 4 \alpha\beta} .
\end{align}
$$

Since the coefficient $a \neq 0$, we can divide the quadratic equation by $a$ to obtain a [monic](https://en.wikipedia.org/wiki/Monic_polynomial) polynomial with the same roots. Namely,

$$
x^2 + \frac{b}{a}x + \frac{c}{a}
= (x - \alpha)(x - \beta)
= x^2 - (\alpha + \beta)x + \alpha\beta .
$$

This implies that the sum $\alpha + \beta = -\tfrac ba$ and the product $\alpha\beta = \tfrac ca$. Thus the identity can be rewritten:

$$
\alpha - \beta
= \pm\sqrt{\left(-\frac{b}{a}\right)^2-4\frac{c}{a}}
= \pm\frac{\sqrt{b^2 - 4ac}}{a} .
$$

Therefore,

$$
\begin{align}
\alpha &= \tfrac12(\alpha + \beta) + \tfrac12(\alpha - \beta)
        = -\frac{b}{2a} \pm \frac{\sqrt{b^2 - 4ac}}{2a}, \\[10mu]
\beta  &= \tfrac12(\alpha + \beta) - \tfrac12(\alpha - \beta)
        = -\frac{b}{2a} \mp \frac{\sqrt{b^2 - 4ac}}{2a}.
\end{align}
$$

The two possibilities for each of $\alpha$ and $\beta$ are the same two roots in opposite order, so we can combine them into the standard quadratic equation:

$$x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a} .$$

### By Lagrange resolvents

*Further information:* [*Lagrange resolvents*](https://en.wikipedia.org/wiki/Lagrange_resolvents)

An alternative way of deriving the quadratic formula is via the method of [Lagrange resolvents](https://en.wikipedia.org/wiki/Lagrange_resolvents), which is an early part of [Galois theory](https://en.wikipedia.org/wiki/Galois_theory). This method can be generalized to give the roots of [cubic polynomials](https://en.wikipedia.org/wiki/Cubic_polynomial) and [quartic polynomials](https://en.wikipedia.org/wiki/Quartic_polynomial), and leads to Galois theory, which allows one to understand the solution of algebraic equations of any degree in terms of the [symmetry group](https://en.wikipedia.org/wiki/Symmetry_group) of their roots, the [Galois group](https://en.wikipedia.org/wiki/Galois_group).

This approach focuses on the roots themselves rather than algebraically rearranging the original equation. Given a monic quadratic polynomial $x^2 + px + q$ assume that $\alpha$ and $\beta$ are the two roots. So the polynomial factors as

$$
\begin{align}
x^2+px+q &= (x-\alpha)(x-\beta) \\[3mu]
         &= x^2-(\alpha+\beta)x+\alpha\beta
\end{align}
$$

which implies $p = -(\alpha + \beta)$ and $q = \alpha\beta$.

Since multiplication and addition are both [commutative](https://en.wikipedia.org/wiki/Commutative_property), exchanging the roots $\alpha$ and $\beta$ will not change the coefficients $p$ and $q$: one can say that $p$ and $q$ are [symmetric polynomials](https://en.wikipedia.org/wiki/Symmetric_polynomials) in $\alpha$ and $\beta$. Specifically, they are the [elementary symmetric polynomials](https://en.wikipedia.org/wiki/Elementary_symmetric_polynomials) – any symmetric polynomial in $\alpha$ and $\beta$ can be expressed in terms of $\alpha + \beta$ and $\alpha\beta$ instead.

The Galois theory approach to analyzing and solving polynomials is to ask whether, given coefficients of a polynomial each of which is a symmetric function in the roots, one can "break" the symmetry and thereby recover the roots. Using this approach, solving a polynomial of degree $n$ is related to the ways of rearranging ("[permuting](https://en.wikipedia.org/wiki/Permutation)") $n$ terms, called the [symmetric group](https://en.wikipedia.org/wiki/Symmetric_group) on $n$ letters and denoted $S_n$. For the quadratic polynomial, the only ways to rearrange two roots are to either leave them be or to [transpose](<https://en.wikipedia.org/wiki/Transposition_(mathematics)>) them, so solving a quadratic polynomial is simple.

To find the roots $\alpha$ and $\beta$, consider their sum and difference:

$$r_1 = \alpha + \beta, \quad r_2 = \alpha - \beta .$$

These are called the *Lagrange resolvents* of the polynomial, from which the roots can be recovered as

$$\alpha = \tfrac12 (r_1 + r_2), \quad \beta = \tfrac12(r_1 - r_2).$$

Because $r_1 = \alpha + \beta$ is a symmetric function in $\alpha$ and $\beta$, it can be expressed in terms of $p$ and $q,$ specifically $r_1 = -p$ as described above. However, $r_2 = \alpha - \beta$ is not symmetric, since exchanging $\alpha$ and $\beta$ yields the [additive inverse $-r_2 = \beta - \alpha$](https://en.wikipedia.org/wiki/Additive_inverse). So $r_2$ cannot be expressed in terms of the symmetric polynomials. However, its square $r_2^2 = (\alpha - \beta)^2$ *is* symmetric in the roots, expressible in terms of $p$ and $q$. Specifically $r_2^2 = (\alpha - \beta)^2 = {}$$(\alpha + \beta)^2 - 4\alpha\beta = {}$$p^2 - 4q$, which implies $r_2 = \pm \sqrt{p^2 - 4q}$. Taking the positive root "breaks" the symmetry, resulting in

$$r_1 = -p, \qquad r_2 = {\textstyle \sqrt{p^2 - 4q}}$$

from which the roots $\alpha$ and $\beta$ are recovered as

$$
x = \tfrac12(r_1 \pm r_2)
= \tfrac{1}{2} \bigl({-p} \pm {\textstyle \sqrt{p^2 - 4q}}\,\bigr)
$$

which is the quadratic formula for a monic polynomial.

Substituting $p = b/a$, $q = c/a$ yields the usual expression for an arbitrary quadratic polynomial. The resolvents can be recognized as

$$
\tfrac12 r_1 = -\tfrac12p = -\frac{b}{2a}, \qquad
r_2^2 = p_2 - 4q = \frac{b^2 - 4ac}{a^2},
$$

respectively the vertex and the discriminant of the monic polynomial.

A similar but more complicated method works for [cubic equations](https://en.wikipedia.org/wiki/Cubic_equation), which have three resolvents and a quadratic equation (the "resolving polynomial") relating $r_2$ and $r_3$, which one can solve by the quadratic equation, and similarly for a [quartic equation](https://en.wikipedia.org/wiki/Quartic_equation) ([degree](https://en.wikipedia.org/wiki/Degree_of_a_polynomial) 4), whose resolving polynomial is a cubic, which can in turn be solved. The same method for a [quintic equation](https://en.wikipedia.org/wiki/Quintic_equation) yields a polynomial of degree 24, which does not simplify the problem, and, in fact, solutions to quintic equations in general cannot be expressed using only roots.

## Numerical calculation

The quadratic formula is exactly correct when performed using the idealized arithmetic of [real numbers](https://en.wikipedia.org/wiki/Real_number), but when approximate arithmetic is used instead, for example pen-and-paper arithmetic carried out to a fixed number of decimal places or the [floating-point](https://en.wikipedia.org/wiki/Floating-point_arithmetic) binary arithmetic available on computers, the limitations of the number representation can lead to substantially inaccurate results unless great care is taken in the implementation. Specific difficulties include [catastrophic cancellation](https://en.wikipedia.org/wiki/Catastrophic_cancellation) in computing the sum $-b \pm \sqrt\Delta$ if $b \approx \pm \sqrt\Delta$; catastrophic calculation in computing the discriminant $\Delta = b^2 - 4ac$ itself in cases where $b^2 \approx 4ac$; degeneration of the formula when $a$, $b$, or $c$ is represented as zero or infinite; and possible [overflow or underflow](https://en.wikipedia.org/wiki/Floating-point_arithmetic#Exception_handling) when multiplying or dividing extremely large or small numbers, even in cases where the roots can be accurately represented.

Catastrophic cancellation occurs when two numbers which are approximately equal are subtracted. While each of the numbers may independently be representable to a certain number of digits of precision, the identical leading digits of each number cancel, resulting in a difference of lower relative precision. When $b \approx \sqrt \Delta$, evaluation of $-b + \sqrt \Delta$ causes catastrophic cancellation, as does the evaluation of $-b - \sqrt \Delta$ when $b \approx -\sqrt\Delta$. When using the standard quadratic formula, calculating one of the two roots always involves addition, which preserves the working precision of the intermediate calculations, while calculating the other root involves subtraction, which compromises it. Therefore, naïvely following the standard quadratic formula often yields one result with less relative precision than expected. Unfortunately, introductory algebra textbooks typically do not address this problem, even though it causes students to obtain inaccurate results in other school subjects such as introductory chemistry.

For example, if trying to solve the equation $x^2 - 1634x + 2 = 0$ using a pocket calculator, the result of the quadratic formula $x = 817 \pm \sqrt{667\,487}$ might be approximately calculated as:

$$
\begin{alignat}{3}
x_1 &= 817 + 816.998\,776\,0 &&= 1.633\,998\,776 \times 10^3, \\
x_2 &= 817 - 816.998\,776\,0 &&= 1.224 \times 10^{-3}.
\end{alignat}
$$

Even though the calculator used ten decimal digits of precision for each step, calculating the difference between two approximately equal numbers has yielded a result for $x_2$ with only four correct digits.

One way to recover an accurate result is to use the identity $x_1 x_2 = c/a$. In this example $x_2$ can be calculated as $x_2 = 2 / x_1 = {}$$1.223\,991\,125 \times 10^{-3}\!$, which is correct to the full ten digits. Another more or less equivalent approach is to use the version of the quadratic formula with the square root in the denominator to calculate one of the roots (see [§ Square root in the denominator](https://en.wikipedia.org/wiki/Quadratic_formula#Square_root_in_the_denominator) above).

Practical computer implementations of the solution of quadratic equations commonly choose which formula to use for each root depending on the sign of $b$.

These methods do not prevent possible overflow or underflow of the floating-point exponent in computing $b^2$ or $4ac$, which can lead to numerically representable roots not being computed accurately. A more robust but computationally expensive strategy is to start with the substitution $x = -u \sgn(b)\sqrt{\vert c\vert} \big/\! \sqrt{\vert a\vert}$, turning the quadratic equation into

$$u^2 - 2 \frac{|b|}{2\sqrt{|a|}\sqrt{|c|}}u + \sgn(c) = 0,$$

where $\sgn$ is the [sign function](https://en.wikipedia.org/wiki/Sign_function). Letting $d = \vert b\vert\big/2\sqrt{\vert a\vert}\sqrt{\vert c\vert}$, this equation has the form $u^2 - 2du \pm 1 = 0$, for which one solution is $u_1 = d + \sqrt{d^2 \mp 1}$ and the other solution is $u_2 = \pm1 / u_1$. The roots of the original equation are then $x_1 = -\sgn(b)\bigl(\sqrt{\vert c\vert} \big/\!\sqrt{\vert a\vert}~\!\bigr) u_1$ and $x_2 = -\sgn(b)\bigl(\sqrt{\vert c\vert} \big/\!\sqrt{\vert a\vert}~\!\bigr) u_2$.

With additional complication the expense and extra rounding of the square roots can be avoided by approximating them as [powers of two](https://en.wikipedia.org/wiki/Power_of_two), while still avoiding exponent overflow for representable roots.

## Historical development

The earliest methods for solving quadratic equations were geometric. Babylonian cuneiform tablets contain problems reducible to solving quadratic equations. The Egyptian [Berlin Papyrus](https://en.wikipedia.org/wiki/Berlin_Papyrus_6619), dating back to the [Middle Kingdom](https://en.wikipedia.org/wiki/Middle_Kingdom_of_Egypt) (2050 BC to 1650 BC), contains the solution to a two-term quadratic equation.

The Greek mathematician [Euclid](https://en.wikipedia.org/wiki/Euclid) (circa 300 BC) used geometric methods to solve quadratic equations in Book 2 of his [*Elements*](https://en.wikipedia.org/wiki/Euclid's_Elements), an influential mathematical treatise Rules for quadratic equations appear in the Chinese [*The Nine Chapters on the Mathematical Art*](https://en.wikipedia.org/wiki/The_Nine_Chapters_on_the_Mathematical_Art) circa 200 BC. In his work [*Arithmetica*](https://en.wikipedia.org/wiki/Arithmetica), the Greek mathematician [Diophantus](https://en.wikipedia.org/wiki/Diophantus) (circa 250 AD) solved quadratic equations with a method more recognizably algebraic than the [geometric algebra](https://en.wikipedia.org/wiki/Geometric_algebra) of Euclid. His solution gives only one root, even when both roots are positive.

The [Indian mathematician](https://en.wikipedia.org/wiki/Indian_mathematics) [Brahmagupta](https://en.wikipedia.org/wiki/Brahmagupta) included a generic method for finding one root of a quadratic equation in his treatise [*Brāhmasphuṭasiddhānta*](https://en.wikipedia.org/wiki/Br%C4%81hmasphu%E1%B9%ADasiddh%C4%81nta) (circa 628 AD), written out in words in the style of that time. His solution of the quadratic equation $ax^2 + bx = c$ was as follows: "To the absolute number multiplied by four times the [coefficient of the] square, add the square of the [coefficient of the] middle term; the square root of the same, less the [coefficient of the] middle term, being divided by twice the [coefficient of the] square is the value." In modern notation, this can be written $x = \bigl(\sqrt{c \cdot 4a + b^2} - b\bigr) \big/ 2a$. The Indian mathematician [Śrīdhara](https://en.wikipedia.org/wiki/%C5%9Ar%C4%ABdhara) (8th–9th century) came up with a similar algorithm for solving quadratic equations in a now-lost work on algebra quoted by [Bhāskara II](https://en.wikipedia.org/wiki/Bh%C4%81skara_II). The modern quadratic formula is sometimes called *Sridharacharya's formula* in India and *Bhaskara's formula* in Brazil.

The 9th-century Persian mathematician [Muḥammad ibn Mūsā al-Khwārizmī](https://en.wikipedia.org/wiki/Mu%E1%B8%A5ammad_ibn_M%C5%ABs%C4%81_al-Khw%C4%81rizm%C4%AB) solved quadratic equations algebraically. The quadratic formula covering all cases was first obtained by [Simon Stevin](https://en.wikipedia.org/wiki/Simon_Stevin) in 1594. In 1637 [René Descartes](https://en.wikipedia.org/wiki/Ren%C3%A9_Descartes) published [*La Géométrie*](https://en.wikipedia.org/wiki/La_G%C3%A9om%C3%A9trie) containing special cases of the quadratic formula in the form we know today.

## Geometric significance

In terms of coordinate geometry, an axis-aligned parabola is a curve whose $(x, y)$-coordinates are the [graph](https://en.wikipedia.org/wiki/Graph_of_a_function) of a second-degree polynomial, of the form $y = ax^2 + bx + c$, where $a$, $b$, and $c$ are real-valued constant coefficients with $a \neq 0$.

Geometrically, the quadratic formula defines the points $(x, 0)$ on the graph, where the parabola crosses the $x$-axis. Furthermore, it can be separated into two terms,

$$
x = \frac{-b\pm\sqrt{b^2 - 4ac }}{2a}
= -\frac{b}{2a} \pm \frac{\sqrt{b^2 - 4ac}}{2a}.
$$

The first term describes the [axis of symmetry](https://en.wikipedia.org/wiki/Axis_of_symmetry), the line $x = -\tfrac{b}{2a}$. The second term, $\sqrt{b^2 - 4ac}\big/ 2a$, gives the distance the roots are away from the axis of symmetry.

If the parabola's vertex is on the $x$-axis, then the corresponding equation has a single repeated root on the line of symmetry, and this distance term is zero; algebraically, the discriminant $b^2 - 4ac = 0$.

If the discriminant is positive, then the vertex is not on the $x$-axis but the parabola opens in the direction of the $x$-axis, crossing it twice, so the corresponding equation has two real roots. If the discriminant is negative, then the parabola opens in the opposite direction, never crossing the $x$-axis, and the equation has no real roots; in this case the two complex-valued roots will be [complex conjugates](https://en.wikipedia.org/wiki/Complex_conjugate) whose real part is the $x$ value of the axis of symmetry.

## Dimensional analysis

If the constants $a$, $b$, and/or $c$ are not [unitless](https://en.wikipedia.org/wiki/Unitless) then the quantities $x$ and $\tfrac ba$ must have the same units, because the terms $ax^2$ and $bx$ agree on their units. By the same logic, the coefficient $c$ must have the same units as $\tfrac{b^2}{a}$, irrespective of the units of $x$. This can be a powerful tool for verifying that a quadratic expression of [physical quantities](https://en.wikipedia.org/wiki/Physical_quantities) has been set up correctly.

## See also

- [Fundamental theorem of algebra](https://en.wikipedia.org/wiki/Fundamental_theorem_of_algebra)
- [Vieta's formulas](https://en.wikipedia.org/wiki/Vieta's_formulas)

## Notes

1. *Sterling, Mary Jane (2010),* [*Algebra I For Dummies*](https://books.google.com/books?id=2toggaqJMzEC&q=quadratic+formula&pg=PA219)*, Wiley Publishing, p. 219,* [*ISBN*](<https://en.wikipedia.org/wiki/ISBN_(identifier)>) [*978-0-470-55964-2*](https://en.wikipedia.org/wiki/Special:BookSources/978-0-470-55964-2)
2. [*"Discriminant review"*](https://www.khanacademy.org/math/algebra/x2f8bb11595b61c86:quadratic-functions-equations/x2f8bb11595b61c86:quadratic-formula-a1/a/discriminant-review)*, Khan Academy, retrieved 2019-11-10*
3. [*"Understanding the quadratic formula"*](https://www.khanacademy.org/math/algebra/x2f8bb11595b61c86:quadratic-functions-equations/x2f8bb11595b61c86:quadratic-formula-a1/a/quadratic-formula-explained-article)*, Khan Academy, retrieved 2019-11-10*
4. [*"Axis of Symmetry of a Parabola. How to find axis from equation or from a graph. To find the axis of symmetry ..."*](https://www.mathwarehouse.com/geometry/parabola/axis-of-symmetry.php)*, www.mathwarehouse.com, retrieved 2019-11-10*
5. *Rich, Barnett; Schmidt, Philip (2004),* [*Schaum's Outline of Theory and Problems of Elementary Algebra*](https://books.google.com/books?id=8PRU9cTKprsC)*, The McGraw–Hill Companies,* [*Chapter 13 §4.4, p. 291*](https://books.google.com/books?id=8PRU9cTKprsC&pg=PA291)*,* [*ISBN*](<https://en.wikipedia.org/wiki/ISBN_(identifier)>) [*0-07-141083-X*](https://en.wikipedia.org/wiki/Special:BookSources/0-07-141083-X)
6. Li, Xuhui. *An Investigation of Secondary School Algebra Teachers' Mathematical Knowledge for Teaching Algebraic Equation Solving*, p. 56 (ProQuest, 2007): "The quadratic formula is the most general method for solving quadratic equations and is derived from another general method: completing the square."
7. Rockswold, Gary. *College algebra and trigonometry and precalculus*, p. 178 (Addison Wesley, 2002).
8. Beckenbach, Edwin et al. *Modern college algebra and trigonometry*, p. 81 (Wadsworth Pub. Co., 1986).
9. Specifically, Fagnano began with the equation $xx + bb = ax$ and found the solutions to be

   $$x = \frac{2 bb}{a \mp a \sqrt{1 - \dfrac{4bb}{aa}}}.$$

   (In the 18th century, the square $x^2$ was conventionally written as $xx$.)

   [*Fagnano, Giulio Carlo*](https://en.wikipedia.org/wiki/Giulio_Carlo_de'_Toschi_di_Fagnano) *(1750),* [*"Applicazione dell' algoritmo nuovo Alla resoluzione analitica dell' equazioni del secondo, del terzo, e del quarto grado"*](https://era-prod11.ethz.ch/zut/content/zoom/2406151) *[Application of a new algorithm to the analytical resolution of equations of the second, third, and fourth degree], Produzioni matematiche del conte Giulio Carlo di Fagnano, Marchese de' Toschi, e DiSant' Ononio (in Italian), vol. 1, Pesaro: Gavelliana, Appendice seconda, eq. 6, p. 467,* [*doi*](<https://en.wikipedia.org/wiki/Doi_(identifier)>)*:*[*10.3931/e-rara-8663*](https://doi.org/10.3931%2Fe-rara-8663)
10. *Goff, Gerald K. (1976), "The Citardauq Formula", The Mathematics Teacher, **69** (7): 550–551,* [*doi*](<https://en.wikipedia.org/wiki/Doi_(identifier)>)*:*[*10.5951/MT.69.7.0550*](https://doi.org/10.5951%2FMT.69.7.0550)*,* [*JSTOR*](<https://en.wikipedia.org/wiki/JSTOR_(identifier)>) [*27960584*](https://www.jstor.org/stable/27960584)
11. *Hoehn, Larry (1975), "A More Elegant Method of Deriving the Quadratic Formula", The Mathematics Teacher, **68** (5): 442–443,* [*doi*](<https://en.wikipedia.org/wiki/Doi_(identifier)>)*:*[*10.5951/MT.68.5.0442*](https://doi.org/10.5951%2FMT.68.5.0442)*,* [*JSTOR*](<https://en.wikipedia.org/wiki/JSTOR_(identifier)>) [*27960212*](https://www.jstor.org/stable/27960212)
12. Starting from a quadratic equation of the form $ax^2 + bx = c$, Śrīdhara's method, as quoted by [Bhāskara II](https://en.wikipedia.org/wiki/Bh%C4%81skara_II) (c. 1150): "Multiply both sides of the equation by a number equal to four times the [coefficient of the] square, and add to them a number equal to the square of the original [coefficient of the] unknown quantity. [Then extract the root.]".

    [Smith 1923](https://en.wikipedia.org/wiki/Quadratic_formula#CITEREFSmith1923), [p. 446](https://archive.org/details/historyofmathema0001davi/page/446)
13. *Debnath, Lokenath (2009), "The legacy of Leonhard Euler – a tricentennial tribute", International Journal of Mathematical Education in Science and Technology, **40** (3): 353–388,* [*doi*](<https://en.wikipedia.org/wiki/Doi_(identifier)>)*:*[*10.1080/00207390802642237*](https://doi.org/10.1080%2F00207390802642237)
14. Clark, A. (1984). *Elements of abstract algebra*. Courier Corporation. p. 146.
15. *Prasolov, Viktor; Solovyev, Yuri (1997),* [*Elliptic functions and elliptic integrals*](https://books.google.com/books?id=fcp9IiZd3tQC&pg=PA134)*, AMS Bookstore, p. 134,* [*ISBN*](<https://en.wikipedia.org/wiki/ISBN_(identifier)>) [*978-0-8218-0587-9*](https://en.wikipedia.org/wiki/Special:BookSources/978-0-8218-0587-9)
16. [*Forsythe, George E.*](https://en.wikipedia.org/wiki/George_E._Forsythe) *(1969),* [*"Solving a Quadratic Equation on a Computer"*](https://archive.org/details/1969.-bers-the-mathematical-sciences.-a-collection-of-essays/page/138/)*, The Mathematical Sciences: A Collection of Essays, MIT Press, pp. 138–152,* [*ISBN*](<https://en.wikipedia.org/wiki/ISBN_(identifier)>) [*0-262-03026-8*](https://en.wikipedia.org/wiki/Special:BookSources/0-262-03026-8)
17. *Goualard, Frédéric (2023), The Ins and Outs of Solving Quadratic Equations with Floating-Point Arithmetic (Technical report), University of Nantes,* [*HAL*](<https://en.wikipedia.org/wiki/HAL_(open_archive)>) [*hal-04116310*](https://hal.archives-ouvertes.fr/hal-04116310)
18. *Thompson, H. Bradford (1987), "Good numerical technique in chemistry: The quadratic equation", Journal of Chemical Education, **64** (12): 1009,* [*doi*](<https://en.wikipedia.org/wiki/Doi_(identifier)>)*:*[*10.1021/ed064p1009*](https://doi.org/10.1021%2Fed064p1009)
19. This example comes from:

    [*Henrici, Peter*](<https://en.wikipedia.org/wiki/Peter_Henrici_(mathematician)>) *(1982), Essentials of Numerical Analysis with Pocket Calculator Demonstrations, New York: Wiley, p. 13*
20. *Forsythe, George E. (1966),* [*How Do You Solve a Quadratic Equation*](https://apps.dtic.mil/sti/tr/pdf/AD0639052.pdf) *(PDF) (Tech report), Stanford University, STAN-CS-66-40 (AD639052)*
21. *Baker, Henry G. (1998), "You Could Learn a Lot from a Quadratic: Overloading Considered Harmful", SIGPLAN Notices, **33** (1): 30–38,* [*doi*](<https://en.wikipedia.org/wiki/Doi_(identifier)>)*:*[*10.1145/609742.609746*](https://doi.org/10.1145%2F609742.609746)
22. *Mastronardi, Nicola; Van Dooren, Paul (2015),* [*"Revisiting the stability of computing the roots of a quadratic polynomial"*](https://web.archive.org/web/20250303201801/https://etna.math.kent.edu/volumes/2011-2020/vol44/abstract.php?vol=44)*, Electronic Transactions on Numerical Analysis, **44**: 73–83,* [*arXiv*](<https://en.wikipedia.org/wiki/ArXiv_(identifier)>)*:*[*1409.8072*](https://arxiv.org/abs/1409.8072)*, archived from* [*the original*](https://etna.math.kent.edu/volumes/2011-2020/vol44/abstract.php?vol=44&pages=73-82) *on 2025-03-03, retrieved 2024-03-15*
23. [Irving 2013](https://en.wikipedia.org/wiki/Quadratic_formula#CITEREFIrving2013), p. 34.
24. [*The Cambridge Ancient History Part 2 Early History of the Middle East*](https://books.google.com/books?id=slR7SFScEnwC&pg=PA530)*, Cambridge University Press, 1971, p. 530,* [*ISBN*](<https://en.wikipedia.org/wiki/ISBN_(identifier)>) [*978-0-521-07791-0*](https://en.wikipedia.org/wiki/Special:BookSources/978-0-521-07791-0)
25. [Irving 2013](https://en.wikipedia.org/wiki/Quadratic_formula#CITEREFIrving2013), p. 39.
26. *Aitken, Wayne,* [*"A Chinese Classic: The Nine Chapters"*](http://public.csusm.edu/aitken_html/m330/china/ninechapters.pdf) *(PDF), Mathematics Department, California State University, retrieved 28 April 2013*
27. [Smith 1923](https://en.wikipedia.org/wiki/Quadratic_formula#CITEREFSmith1923), [p. 380](https://archive.org/details/historyofmathema0001davi/page/380).
28. [Smith 1923](https://en.wikipedia.org/wiki/Quadratic_formula#CITEREFSmith1923), [p. 134](https://archive.org/details/historyofmathema0001davi/page/134).
29. Bradley, Michael. *The Birth of Mathematics: Ancient Times to 1300*, p. 86 (Infobase Publishing 2006).
30. Mackenzie, Dana. *The Universe in Zero Words: The Story of Mathematics as Told through Equations*, p. 61 (Princeton University Press, 2012).
31. *Stillwell, John (2004), Mathematics and Its History (2nd ed.), Springer, p. 87,* [*ISBN*](<https://en.wikipedia.org/wiki/ISBN_(identifier)>) [*0-387-95336-1*](https://en.wikipedia.org/wiki/Special:BookSources/0-387-95336-1)
32. *O'Connor, John J.;* [*Robertson, Edmund F.*](https://en.wikipedia.org/wiki/Edmund_F._Robertson) *(2000),* [*"Sridhara"*](https://mathshistory.st-andrews.ac.uk/Biographies/Sridhara.html)*,* [*MacTutor History of Mathematics Archive*](https://en.wikipedia.org/wiki/MacTutor_History_of_Mathematics_Archive)*,* [*University of St Andrews*](https://en.wikipedia.org/wiki/University_of_St_Andrews)
33. *Rocha, Rodrigo Luis da (2023). O uso da expressão 'fórmula de bhaskara' em livros didáticos brasileiros e sua relação com o método resolutivo da equação do 2º grau \[The use of the expression 'bhaskara formula' in Brazilian textbooks and its relationship with the method for solving quadratic equations] (master's thesis) (in Portuguese). Universidade Federal do Paraná.* [*hdl*](<https://en.wikipedia.org/wiki/Hdl_(identifier)>)*:*[*1884/82597*](https://hdl.handle.net/1884%2F82597)*.*

    *Guedes, Eduardo Gomes (2019). A equação quadrática e as contribuições de Bhaskara \[The quadratic equation and Bhaskara's contributions] (master's thesis) (in Portuguese). Universidade Federal do Paraná.* [*hdl*](<https://en.wikipedia.org/wiki/Hdl_(identifier)>)*:*[*1884/66582*](https://hdl.handle.net/1884%2F66582)*.*

    *Banerjee, Isha (July 2, 2024).* [*"India Molded Math. Then Europe Claimed It"*](https://www.thejuggernaut.com/fibonacci-sequence-indian-math-history-quadratic-formula)*. The Juggernaut. For instance, some Indian schools call the quadratic formula Sridharacharya's formula and some Brazilian schools call it Bhaskara's formula.*
34. [Irving 2013](https://en.wikipedia.org/wiki/Quadratic_formula#CITEREFIrving2013), p. 42.
35. [*Struik, D. J.*](https://en.wikipedia.org/wiki/Dirk_Jan_Struik)*; Stevin, Simon (1958),* [*The Principal Works of Simon Stevin, Mathematics*](https://web.archive.org/web/20210224142514/https://www.dwc.knaw.nl/pub/bronnen/Simon_Stevin-%5BII_B%5D_The_Principal_Works_of_Simon_Stevin,_Mathematics.pdf) *(PDF), vol. II–B, C. V. Swets & Zeitlinger, p. 470, archived from* [*the original*](http://www.dwc.knaw.nl/pub/bronnen/Simon_Stevin-%5BII_B%5D_The_Principal_Works_of_Simon_Stevin,_Mathematics.pdf) *(PDF) on 2021-02-24, retrieved 2013-10-11*
36. *Rene Descartes,* [*The Geometry*](http://archive.org/details/TheGeometry)

## References

⟦picture 3⟧

Wikimedia Commons has media related to [***Quadratic formula***](https://commons.wikimedia.org/wiki/Category:Quadratic%20formula).

- [*Smith, David Eugene*](https://en.wikipedia.org/wiki/David_Eugene_Smith) *(1923),* [*History of Mathematics*](https://archive.org/details/historyofmathema0001davi/)*, vol. 2, Boston: Ginn*
- *Irving, Ron (2013),* [*Beyond the Quadratic Formula*](https://books.google.com/books?id=CV_UInCRO38C)*, MAA,* [*ISBN*](<https://en.wikipedia.org/wiki/ISBN_(identifier)>) [*978-0-88385-783-0*](https://en.wikipedia.org/wiki/Special:BookSources/978-0-88385-783-0)

| • [v](https://en.wikipedia.org/wiki/Template:Polynomials)<br>• [t](https://en.wikipedia.org/wiki/Template_talk:Polynomials)<br>• [e](https://en.wikipedia.org/wiki/Special:EditPage/Template:Polynomials)<br>[Polynomials](https://en.wikipedia.org/wiki/Polynomial), [polynomial functions](https://en.wikipedia.org/wiki/Polynomial_function) and [polynomial equations](https://en.wikipedia.org/wiki/Polynomial_equation) |  |
| :-: | --- |
| By [degree](https://en.wikipedia.org/wiki/Degree_of_a_polynomial) | • [Zero polynomial (degree undefined or −1 or −∞)](https://en.wikipedia.org/wiki/Zero_polynomial)<br>• [Constant function (0)](https://en.wikipedia.org/wiki/Constant_function)<br>• [Linear function (1)](<https://en.wikipedia.org/wiki/Linear_function_(calculus)>)<br>• [Linear equation](https://en.wikipedia.org/wiki/Linear_equation)<br>• [Quadratic function (2)](https://en.wikipedia.org/wiki/Quadratic_function)<br>• [Quadratic equation](https://en.wikipedia.org/wiki/Quadratic_equation)<br>• [Cubic function (3)](https://en.wikipedia.org/wiki/Cubic_function)<br>• [Cubic equation](https://en.wikipedia.org/wiki/Cubic_equation)<br>• [Quartic function (4)](https://en.wikipedia.org/wiki/Quartic_function)<br>• [Quartic equation](https://en.wikipedia.org/wiki/Quartic_equation)<br>• [Quintic equation (5)](https://en.wikipedia.org/wiki/Quintic_equation)<br>• [Sextic equation (6)](https://en.wikipedia.org/wiki/Sextic_equation)<br>• [Septic equation (7)](https://en.wikipedia.org/wiki/Septic_equation) |
| By properties | • [Univariate](https://en.wikipedia.org/wiki/Univariate_polynomial)<br>• [Bivariate](https://en.wikipedia.org/wiki/Bivariate_polynomial)<br>• [Multivariate](https://en.wikipedia.org/wiki/Multivariate_polynomial)<br>• [Monomial](https://en.wikipedia.org/wiki/Monomial)<br>• [Binomial](<https://en.wikipedia.org/wiki/Binomial_(polynomial)>)<br>• [Trinomial](https://en.wikipedia.org/wiki/Trinomial)<br>• [Irreducible](https://en.wikipedia.org/wiki/Irreducible_polynomial)<br>• [Square-free](https://en.wikipedia.org/wiki/Square-free_polynomial)<br>• [Homogeneous](https://en.wikipedia.org/wiki/Homogeneous_polynomial)<br>• [Quasi-homogeneous](https://en.wikipedia.org/wiki/Quasi-homogeneous_polynomial) |
| Tools and algorithms | • [Factorization](https://en.wikipedia.org/wiki/Factorization_of_polynomials)<br>• [Greatest common divisor](https://en.wikipedia.org/wiki/Polynomial_greatest_common_divisor)<br>• [Division](https://en.wikipedia.org/wiki/Polynomial_long_division)<br>• [Horner's method of evaluation](https://en.wikipedia.org/wiki/Horner's_method)<br>• [Polynomial identity testing](https://en.wikipedia.org/wiki/Polynomial_identity_testing)<br>• [Resultant](https://en.wikipedia.org/wiki/Resultant)<br>• [Discriminant](https://en.wikipedia.org/wiki/Discriminant)<br>• [Gröbner basis](https://en.wikipedia.org/wiki/Gr%C3%B6bner_basis) |
<!--
picture 1 at 181: https://thumb.wikimedia.org/wikipedia/commons/thumb/6/63/Roots_of_a_quadratic_function_via_the_quadratic_formula.png/250px-Roots_of_a_quadratic_function_via_the_quadratic_formula.png?utm_source=en.wikipedia.org&utm_campaign=parser&utm_content=thumbnail, alt "A graph of a parabola-shaped function which intersects the x-axis at x = 1 and x = 5", 250x219, width 0.35
picture 2 at 2696: https://thumb.wikimedia.org/wikipedia/commons/thumb/3/39/Quadratic_formula_via_completing_the_square.png/330px-Quadratic_formula_via_completing_the_square.png?utm_source=en.wikipedia.org&utm_campaign=parser&utm_content=thumbnail, 310x178, width 0.43
picture 3 at 37040: https://thumb.wikimedia.org/wikipedia/en/thumb/4/4a/Commons-logo.svg/40px-Commons-logo.svg.png?utm_source=en.wikipedia.org&utm_campaign=parser&utm_content=thumbnail, alt "Wikimedia Commons logo", 30x40, width 0.25
-->
