import ast, pathlib, tomllib
root = pathlib.Path.cwd()
source = root/'rust/scripts/check-readonly.py'
tree=ast.parse(source.read_text())
function=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='assert_boundaries')
namespace={'ROOT':root,'tomllib':tomllib}
exec(compile(ast.Module(body=[function],type_ignores=[]),str(source),'exec'),namespace)
namespace['assert_boundaries']()
print('actual assert_boundaries: PASS (no builds, no daemon)')
