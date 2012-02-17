class Twostroke::Compiler::Binary
  attr_accessor :bytecode, :ast
  
  def initialize(ast)
    @ast = ast
    @sections = [[]]
    @section_stack = [0]
    @scope_stack = []
    @interned_strings = {}
    @continue_stack = []
    @break_stack = []
    @label_ai = 0
  end
  
  def compile
    ast.each &method(:hoist)
    ast.each &method(:compile_node)
    output :undefined
    output :ret
    generate_bytecode
  end
  
  OPCODES = {
    undefined:  0,
    ret:        1,
    pushnum:    2,
    add:        3,
    pushglobal: 4,
    pushstr:    5,
    methcall:   6,
    setvar:     7,
    pushvar:    8,
    true:       9,
    false:      10,
    null:       11,
    jmp:        12,
    jit:        13,
    jif:        14,
    sub:        15,
    mul:        16,
    div:        17,
    setglobal:  18,
    close:      19,
    call:       20,
    setcallee:  21,
    setarg:     22,
    lt:         23,
    lte:        24,
    gt:         25,
    gte:        26,
    pop:        27,
    array:      28,
  }

private

  def generate_bytecode
    @bytecode = "JSX\0"
    # how many sections exist as LE uint32_t:
    bytecode << [@sections.size].pack("L<")
    @sections.map(&method(:generate_bytecode_for_section)).each do |sect|
      bytecode << [sect.size].pack("L<") << sect
    end
    bytecode << [@interned_strings.count].pack("L<")
    @interned_strings.each do |str,idx|
      bytecode << [str.bytes.count].pack("L<")
      bytecode << str << "\0"
    end
  end
  
  def generate_bytecode_for_section(section)
    acc = 0
    label_refs = {}
    section.each do |sect|
      if sect.is_a? Array
        fixup, arg = sect
        case fixup
        when :label;  label_refs[arg] = acc / 4
        when :ref;    acc += 4
        end
      else
        acc += sect.bytes.count
      end
    end
    section.reject { |a,b| a == :label }.map { |x| x.is_a?(Array) ? [label_refs[x[1]]].pack("L<") : x }.join
  end

  def current_section
    @sections[@section_stack.last]
  end

  def push_section(section = nil)
    unless section
      @section_stack << @sections.size
      @sections << []
    else
      @section_stack << section
    end  
    @section_stack.last
  end
  
  def pop_section
    @section_stack.pop
  end
  
  def push_scope
    @scope_stack << { }
  end
  
  def pop_scope
    @scope_stack.pop
  end
  
  def create_local_var(var)
    if @scope_stack.any?
      @scope_stack.last[var] ||= @scope_stack.last.count
    end
  end
  
  def lookup_var(var)
    @scope_stack.reverse_each.each_with_index do |scope, index|
      return [scope[var], index] if scope[var]
    end
    nil
  end

  def compile_node(node)
    if respond_to? type(node), true
      send type(node), node
    else
      raise "unimplemented node type #{type(node)}"
    end
  end
  
  def intern_string(str)
    @interned_strings[str] ||= @interned_strings.count
  end
  
  def output(*ops)
    ops.each do |op|
      case op
      when Symbol
        raise "unknown op #{op.inspect}" unless OPCODES[op]
        current_section << [OPCODES[op]].pack("L<")
      when Float
        current_section << [op].pack("E")
      when Fixnum
        current_section << [op].pack("L<")
      when String
        current_section << [intern_string(op)].pack("L<")
      when Array
        current_section << op # this is a fixup to be resolved later
      else
        raise "bad op type #{op.class.name}"
      end
    end
  end
  
  def type(node)
    node.class.name.split("::").last.intern
  end
  
  def hoist(node)
    node.walk do |node|
      if node.is_a? Twostroke::AST::Declaration
        create_local_var node.name
      elsif node.is_a? Twostroke::AST::Function
        if node.name
          create_local_var node.name
          # because javascript is odd, entire function bodies need to be hoisted, not just their declarations
          Function(node, true)
        end
        false
      else
        true
      end
    end
  end
  
  def uniqid
    @label_ai += 1
  end
  
  # ast node compilers
  
  { Addition: :add, Subtraction: :sub, Multiplication: :mul, Division: :div,
    Equality: :eq, StrictEquality: :seq, LessThan: :lt, GreaterThan: :gt,
    LessThanEqual: :lte, GreaterThanEqual: :gte, BitwiseAnd: :and,
    BitwiseOr: :or, BitwiseXor: :xor, In: :in, RightArithmeticShift: :sar,
    LeftShift: :sal, RightLogicalShift: :slr, InstanceOf: :instanceof,
    Modulus: :mod
  }.each do |method,op|
    define_method method do |node|
      if node.assign_result_left
        if type(node.left) == :Variable || type(node.left) == :Declaration
          compile_node node.left
          compile_node node.right
          output op
          idx, sc = lookup_var node.left.name
          if idx
            output :setvar, idx, sc
          else
            output :setglobal, node.left.name
          end
        elsif type(node.left) == :MemberAccess
          compile_node node.left.object
          output :dup
          output :member, node.left.member
          compile_node node.right
          output op
          output :setprop, node.left.member          
        elsif type(node.left) == :Index
          compile_node node.left.object
          compile_node node.left.index
          output :dup, 2
          output :index
          compile_node node.right
          output op
          output :setindex
        else
          error! "Bad lval in combined operation/assignment"
        end
      else
        compile_node node.left
        compile_node node.right
        output op
      end
    end
    private method
  end
  
  def post_mutate(left, op)
    if type(left) == :Variable || type(left) == :Declaration
      output :push, left.name.intern
      output :dup
      output op
      output :set, left.name.intern
      output :pop
    elsif type(left) == :MemberAccess
      compile left.object
      output :dup
      output :member, left.member.intern
      output :dup
      output :tst
      output op
      output :setprop, left.member.intern
      output :pop
      output :tld
    elsif type(left) == :Index  
      compile left.object
      compile left.index
      output :dup, 2
      output :index
      output :dup
      output :tst
      output op
      output :setindex
      output :pop
      output :tld
    else
      error! "Bad lval in post-mutation"
    end
  end
  
  def PostIncrement(node)
    post_mutate node.value, :inc
  end
  
  def PostDecrement(node)
    post_mutate node.value, :dec
  end
  
  def Function(node, in_hoist_stage = false)
    fnid = node.fnid
    
    if !node.name or in_hoist_stage
      if fnid
        push_section(fnid)
      else
        node.fnid = fnid = push_section
      end
      push_scope
      output :setcallee, create_local_var(node.name) if node.name
      node.arguments.each_with_index do |arg, idx|
        output :setarg, create_local_var(arg), idx
      end
      node.statements.each { |s| hoist s }
      node.statements.each { |s| compile_node s }
      pop_scope
      output :undefined
      output :ret
      pop_section
      output :close, fnid
      if node.name && !node.as_expression
        if idx = create_local_var(node.name)
          output :setvar, create_local_var(node.name), 0 
        else
          output :setglobal, node.name
        end
      end
    else  
      output :close, fnid
    end
  end
  
  def MultiExpression(node)
    compile_node node.left
    output :pop
    compile_node node.right
  end
  
  def Variable(node)
    idx, sc = lookup_var node.name
    if idx
      output :pushvar, idx, sc
    else
      output :pushglobal, node.name
    end
  end
  
  def Number(node)
    output :pushnum, node.number.to_f
  end
  
  def Array(node)
    node.items.each do |item|
      compile_node item
    end
    output :array, node.items.count
  end
  
  def String(node)
    output :pushstr, node.string
  end
  
  def Call(node)
    if type(node.callee) == :MemberAccess
      compile_node node.callee.object
      output :pushstr, node.callee.member.to_s
      node.arguments.each { |n| compile_node n }
      output :methcall, node.arguments.size
    elsif type(node.callee) == :Index
      compile_node node.callee.object
      compile_node node.callee.index
      node.arguments.each { |n| compile_node n }
      output :methcall, node.arguments.size
    else
      compile_node node.callee
      node.arguments.each { |n| compile_node n }
      output :call, node.arguments.size
    end
  end
  
  def Declaration(node)
    # no-op
  end
  
  def Assignment(node)
    if type(node.left) == :Variable || type(node.left) == :Declaration
      compile_node node.right
      idx, sc = lookup_var node.left.name
      if idx
        output :setvar, idx, sc
      else
        output :setglobal, node.left.name
      end
    elsif type(node.left) == :MemberAccess
      compile_node node.left.object
      compile_node node.right
      output :setprop, node.left.name
    elsif type(node.left) == :Index
      compile_node node.left.object
      compile_node node.left.index
      compile_node node.right
      output :setindex
    else  
      error! "Bad lval in assignment"
    end
  end
  
  def Return(node)
    compile_node node.expression
    output :ret
  end
  
  def If(node)
    compile_node node.condition
    else_label = uniqid
    output :jif, [:ref, else_label]
    compile_node node.then
    if node.else
      end_label = uniqid
      output :jmp, [:ref, end_label]
      output [:label, else_label]
      compile_node node.else
      output [:label, end_label]
    else
      output [:label, else_label]
    end
  end
  
  def ForLoop(node, continue_label = nil)
    compile_node node.initializer if node.initializer
    start_label = uniqid
    next_label = uniqid
    end_label = uniqid
    output [:label, start_label]
    if node.condition
      compile_node node.condition
      output :jif, [:ref, end_label]
    end
    @continue_stack.push next_label
    @break_stack.push end_label
    compile_node node.body if node.body
    output [:label, next_label]
    compile_node node.increment if node.increment
    output :jmp, [:ref, start_label]
    output [:label, end_label]
    @continue_stack.pop
    @break_stack.pop
  end
  
  def Body(node)
    node.statements.each &method(:compile_node)
  end
  
  def True(node)
    output :true
  end
  
  def False(node)
    output :false
  end
  
  def Null(node)
    output :null
  end
end