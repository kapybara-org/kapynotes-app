/// Plain-language explanations for the words the calculator colors as
/// operators. These stay separate from parsing so help text cannot affect
/// how an expression is interpreted.
const Map<String, String> calcKeywordHelp = {
  'to': 'Converts the value to another unit or currency.',
  'into': 'Converts the value to another unit or currency.',
  'of': 'Multiplies by the value or amount that follows.',
  'off': 'Subtracts a percentage from the value that follows.',
  'on': 'Adds a percentage to the value that follows.',
  'as': 'Expresses a value in another form, such as a percentage.',
  'in': 'Converts a value to another unit. It can also mean inches.',
  'per': 'Divides the value on the left by the value on the right.',
  'mod': 'Returns the remainder after division.',
  'and': 'Is true when both values are true.',
  'or': 'Is true when either value is true.',
  'xor': 'Is true when exactly one value is true.',
  'not': 'Reverses a true or false value.',
  'a': 'Connects natural-language percentage expressions.',
  'an': 'Connects natural-language percentage expressions.',
  'plus': 'Adds the value on the right to the value on the left.',
  'minus': 'Subtracts the value on the right from the value on the left.',
  'times': 'Multiplies the value on the left by the value on the right.',
  'over': 'Divides the value on the left by the value on the right.',
  'percent': 'Treats the number as a percentage.',
  'pct': 'Treats the number as a percentage.',
};
